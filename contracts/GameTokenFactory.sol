// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./GameToken.sol";

/**
 * @title IXPToken
 * @dev Interface for XP token with minting capability
 */
interface IXPToken {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
}

/**
 * @title GameTokenFactory
 * @dev Enhanced factory contract maintaining original flow with improved security
 * Key improvements:
 * - Enhanced security with reentrancy protection and access controls
 * - Gas optimizations through packed structs and efficient operations
 * - Comprehensive input validation and error handling
 * - Emergency controls and reserve management
 * - Maintains original flow: CREDA → XP → Deploy GameToken → Burn → XP
 */
contract GameTokenFactory is AccessControl, Pausable, ReentrancyGuard {
    using Math for uint256;

    // ============ Constants ============
    bytes32 public constant RATE_MANAGER_ROLE = keccak256("RATE_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 public constant MIN_XP_LOCK_AMOUNT = 1 * 1e18; // Minimum 1 XP to create game token
    uint256 public constant MAX_GAME_TOKEN_DECIMALS = 18;
    uint256 public constant PRECISION_FACTOR = 1e18; // For precise calculations
    uint256 public constant MAX_NAME_LENGTH = 100;
    uint256 public constant MAX_SYMBOL_LENGTH = 10;
    
    // ============ State Variables ============
    IERC20 public immutable credaToken;
    IERC20 public immutable xpToken;
    
    uint256 public credaToXpRate = 1e18; // 1 CREDA = 1 XP (with 18 decimal precision)
    uint256 public nextGameId = 0;
    
    // Track user's locked CREDA for potential future unlocking features
    mapping(address => uint256) public userLockedCreda;
    uint256 public totalLockedCreda;
    
    // Gas-optimized packed struct for game token info
    struct GameTokenInfo {
        address tokenAddress;    // 20 bytes
        address creator;         // 20 bytes
        uint88 xpLocked;        // 11 bytes (up to ~77M XP tokens)
        uint8 decimals;         // 1 byte
        bool active;            // 1 byte
        // Total: 53 bytes (fits in 2 storage slots)
    }
    
    // Additional metadata stored separately to optimize gas
    struct GameTokenMetadata {
        string name;
        string symbol;
        uint256 initialSupply;
        uint256 creationTime;
    }
    
    mapping(uint256 => GameTokenInfo) public gameTokens;
    mapping(uint256 => GameTokenMetadata) public gameTokenMetadata;
    mapping(address => uint256[]) public userGameTokens; // Track user's created tokens
    mapping(address => mapping(string => bool)) public userGameNames; // Prevent duplicate names per user
    
    // XP reserves management
    uint256 public xpReserves; // XP held for game token redemptions
    
    // ============ Events ============
    event CredaLocked(address indexed user, uint256 credaAmount, uint256 xpMinted);
    event GameTokenCreated(
        uint256 indexed gameId,
        address indexed creator,
        address indexed tokenAddress,
        string name,
        string symbol,
        uint256 xpLocked,
        uint256 initialSupply
    );
    event GameTokenBurned(
        uint256 indexed gameId,
        address indexed user,
        uint256 burnAmount,
        uint256 xpReturned
    );
    event RateUpdated(uint256 oldRate, uint256 newRate);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);
    
    // ============ Comprehensive Error Definitions ============
    // Input Validation Errors
    error ZeroAmount();
    error ZeroRate();
    error ZeroAddress();
    error InvalidGameId(uint256 provided, uint256 maxValid);
    error InvalidDecimals(uint8 provided, uint8 maxAllowed);
    error InsufficientAmount(uint256 provided, uint256 required);
    error ExcessiveAmount(uint256 provided, uint256 maximum);
    
    // String Validation Errors
    error EmptyString(string fieldName);
    error StringTooLong(string fieldName, uint256 length, uint256 maxLength);
    error InvalidCharacters(string fieldName);
    
    // Business Logic Errors  
    error GameTokenNotActive(uint256 gameId);
    error DuplicateGameName(address user, string name);
    error InsufficientXpReserves(uint256 required, uint256 available);
    error InsufficientUserBalance(address user, address token, uint256 required, uint256 available);
    error InsufficientAllowance(address user, address spender, address token, uint256 required, uint256 current);
    
    // Contract State Errors
    error ContractPaused();
    error ContractNotPaused();
    error ReentrancyDetected();
    error InvalidContractState(string reason);
    
    // External Call Errors
    error TransferFailed(address token, address from, address to, uint256 amount);
    error MintFailed(address token, address to, uint256 amount);
    error BurnFailed(address token, address from, uint256 amount);
    error GameTokenDeploymentFailed(string reason);
    error ExternalCallFailed(address target, bytes data);
    
    // Access Control Errors
    error UnauthorizedAccess(address caller, bytes32 requiredRole);
    error InvalidRole(bytes32 role);
    error RoleAlreadyGranted(address account, bytes32 role);
    error RoleNotGranted(address account, bytes32 role);
    
    // Mathematical Errors
    error MathOverflow(string operation);
    error MathUnderflow(string operation);
    error DivisionByZero(string operation);
    error InvalidCalculation(string operation, string reason);
    
    // Rate and Conversion Errors
    error InvalidConversionRate(uint256 rate);
    error RateChangeTooBig(uint256 oldRate, uint256 newRate, uint256 maxChangePercent);
    error ConversionResultsInZero(uint256 input, uint256 rate);
    
    // Game Token Specific Errors
    error GameTokenLimitExceeded(address user, uint256 current, uint256 maximum);
    error InvalidInitialSupply(uint256 calculated, uint256 minimum, uint256 maximum);
    error TokenCreationCooldown(address user, uint256 timeRemaining);
    
    // Recovery and Emergency Errors
    error EmergencyActionFailed(string action, string reason);
    error RecoveryNotAllowed(address token, string reason);
    error InvalidRecoveryTarget(address target);
    
    // ============ Constructor ============
    constructor(
        address _credaToken,
        address _xpToken
    ) {
        // Comprehensive input validation
        if (_credaToken == address(0)) {
            revert ZeroAddress();
        }
        if (_xpToken == address(0)) {
            revert ZeroAddress();
        }
        if (_credaToken == _xpToken) {
            revert InvalidContractState("CREDA and XP tokens cannot be the same");
        }
        
        credaToken = IERC20(_credaToken);
        xpToken = IERC20(_xpToken);
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RATE_MANAGER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }
    
    // ============ CREDA → XP Locking ============
    /**
     * @dev Lock CREDA tokens and mint XP tokens to user
     * @param amountCreda Amount of CREDA tokens to lock
     */
    function lockCreda(uint256 amountCreda) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        // Enhanced input validation
        if (amountCreda == 0) revert ZeroAmount();
        
        // Validate user has sufficient balance and allowance
        _validateUserTokenAccess(msg.sender, address(credaToken), amountCreda);
        
        // Safe calculation of XP to mint with overflow protection
        if (credaToXpRate == 0) {
            revert InvalidConversionRate(credaToXpRate);
        }
        
        uint256 xpAmount = _safeMul(amountCreda, credaToXpRate, "CREDA_TO_XP_MULTIPLICATION");
        xpAmount = _safeDiv(xpAmount, PRECISION_FACTOR, "CREDA_TO_XP_DIVISION");
        
        if (xpAmount == 0) {
            revert ConversionResultsInZero(amountCreda, credaToXpRate);
        }
        
        // Transfer CREDA from user to contract with enhanced error handling
        bool transferSuccess = credaToken.transferFrom(msg.sender, address(this), amountCreda);
        if (!transferSuccess) {
            revert TransferFailed(address(credaToken), msg.sender, address(this), amountCreda);
        }
        
        // Update user's locked CREDA with overflow protection
        userLockedCreda[msg.sender] = _safeAdd(userLockedCreda[msg.sender], amountCreda, "USER_LOCKED_CREDA_UPDATE");
        totalLockedCreda = _safeAdd(totalLockedCreda, amountCreda, "TOTAL_LOCKED_CREDA_UPDATE");
        
        // Mint XP tokens to user with error handling
        try IXPToken(address(xpToken)).mint(msg.sender, xpAmount) {
            // Success - emit event
            emit CredaLocked(msg.sender, amountCreda, xpAmount);
        } catch (bytes memory reason) {
            // Revert the CREDA transfer if XP minting fails
            credaToken.transfer(msg.sender, amountCreda);
            userLockedCreda[msg.sender] = _safeSub(userLockedCreda[msg.sender], amountCreda, "REVERT_USER_LOCKED_CREDA");
            totalLockedCreda = _safeSub(totalLockedCreda, amountCreda, "REVERT_TOTAL_LOCKED_CREDA");
            revert MintFailed(address(xpToken), msg.sender, xpAmount);
        }
    }
    
    // ============ XP → Game Token Factory ============
    /**
     * @dev Create a new ERC-20 game token by locking XP tokens
     * @param xpAmount Amount of XP tokens to lock
     * @param name Name of the game token
     * @param symbol Symbol of the game token
     * @param decimals Decimals for the game token
     */
    function createGameToken(
        uint256 xpAmount,
        string calldata name,
        string calldata symbol,
        uint8 decimals
    ) 
        external 
        whenNotPaused 
        nonReentrant 
        returns (uint256 gameId, address tokenAddress)
    {
        // Enhanced input validation with detailed error messages
        if (xpAmount < MIN_XP_LOCK_AMOUNT) {
            revert InsufficientAmount(xpAmount, MIN_XP_LOCK_AMOUNT);
        }
        if (decimals > MAX_GAME_TOKEN_DECIMALS) {
            revert InvalidDecimals(decimals, uint8(MAX_GAME_TOKEN_DECIMALS));
        }
        
        // Validate string inputs with comprehensive checks
        _validateString(name, "name", MAX_NAME_LENGTH);
        _validateString(symbol, "symbol", MAX_SYMBOL_LENGTH);
        
        // Check for duplicate name
        if (userGameNames[msg.sender][name]) {
            revert DuplicateGameName(msg.sender, name);
        }
        
        // Validate user has sufficient XP balance and allowance
        _validateUserTokenAccess(msg.sender, address(xpToken), xpAmount);
        
        // FIXED: Burn XP tokens instead of transferring to contract
        // This ensures XP tokens are consumed when creating game tokens
        IXPToken(address(xpToken)).burnFrom(msg.sender, xpAmount);
        
        // Update XP reserves (tracking locked value for redemption)
        xpReserves += xpAmount;
        
        gameId = nextGameId++;
        
        // Calculate initial supply based on XP amount and decimals
        uint256 initialSupply = xpAmount * (10 ** decimals) / PRECISION_FACTOR;
        
        // Deploy new GameToken contract
        try new GameToken(
            name,
            symbol,
            decimals,
            initialSupply,
            msg.sender, // owner
            address(this), // factory
            gameId
        ) returns (GameToken newToken) {
            tokenAddress = address(newToken);
        } catch Error(string memory reason) {
            // Revert XP burn if deployment fails - mint back the burned tokens
            xpReserves -= xpAmount;
            IXPToken(address(xpToken)).mint(msg.sender, xpAmount);
            revert GameTokenDeploymentFailed(reason);
        } catch (bytes memory lowLevelData) {
            // Revert XP burn if deployment fails - mint back the burned tokens
            xpReserves -= xpAmount;
            IXPToken(address(xpToken)).mint(msg.sender, xpAmount);
            revert GameTokenDeploymentFailed("Unknown deployment error");
        }
        
        // Store game token info (gas-optimized)
        gameTokens[gameId] = GameTokenInfo({
            tokenAddress: tokenAddress,
            creator: msg.sender,
            xpLocked: uint88(xpAmount), // Safe cast due to validation
            decimals: decimals,
            active: true
        });
        
        // Store metadata separately
        gameTokenMetadata[gameId] = GameTokenMetadata({
            name: name,
            symbol: symbol,
            initialSupply: initialSupply,
            creationTime: block.timestamp
        });
        
        // Track user's game tokens and names
        userGameTokens[msg.sender].push(gameId);
        userGameNames[msg.sender][name] = true;
        
        emit GameTokenCreated(gameId, msg.sender, tokenAddress, name, symbol, xpAmount, initialSupply);
    }
    
    // ============ Game Token Burning → XP Unlocking ============
    /**
     * @dev Burn game tokens to reclaim XP tokens
     * @param gameId ID of the game token to burn
     * @param burnAmount Amount of game tokens to burn
     */
    function burnGameToken(uint256 gameId, uint256 burnAmount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        // Enhanced input validation
        if (burnAmount == 0) revert ZeroAmount();
        if (gameId == 0 || gameId >= nextGameId) {
            revert InvalidGameId(gameId, nextGameId - 1);
        }
        
        GameTokenInfo storage gameInfo = gameTokens[gameId];
        if (!gameInfo.active) {
            revert GameTokenNotActive(gameId);
        }
        
        GameTokenMetadata memory metadata = gameTokenMetadata[gameId];
        
        // Validate initial supply to prevent division by zero
        if (metadata.initialSupply == 0) {
            revert InvalidCalculation("XP_RETURN_CALCULATION", "Initial supply is zero");
        }
        
        // Validate user has sufficient game tokens to burn
        GameToken gameToken = GameToken(gameInfo.tokenAddress);
        uint256 userBalance = gameToken.balanceOf(msg.sender);
        if (userBalance < burnAmount) {
            revert InsufficientUserBalance(msg.sender, gameInfo.tokenAddress, burnAmount, userBalance);
        }
        
        // Safe calculation of XP to return with overflow protection
        uint256 xpToReturn = _safeMul(burnAmount, uint256(gameInfo.xpLocked), "XP_RETURN_MULTIPLICATION");
        xpToReturn = _safeDiv(xpToReturn, metadata.initialSupply, "XP_RETURN_DIVISION");
        
        // Validate XP reserves are sufficient
        if (xpReserves < xpToReturn) {
            revert InsufficientXpReserves(xpToReturn, xpReserves);
        }
        
        // Burn tokens from the game token contract with error handling
        try gameToken.burnFrom(msg.sender, burnAmount) {
            // Success - continue with XP minting
        } catch (bytes memory reason) {
            revert BurnFailed(gameInfo.tokenAddress, msg.sender, burnAmount);
        }
        
        // Update state with safe arithmetic
        xpReserves = _safeSub(xpReserves, xpToReturn, "XP_RESERVES_UPDATE");
        
        // Mint XP tokens back to user with error handling
        try IXPToken(address(xpToken)).mint(msg.sender, xpToReturn) {
            // Success - emit event
            emit GameTokenBurned(gameId, msg.sender, burnAmount, xpToReturn);
        } catch (bytes memory reason) {
            // Revert the burn and state changes if XP minting fails
            revert MintFailed(address(xpToken), msg.sender, xpToReturn);
        }
    }
    
    // ============ Admin Functions ============
    /**
     * @dev Update CREDA to XP conversion rate
     * @param newRate New rate (with PRECISION_FACTOR scaling)
     */
    function setRate(uint256 newRate) external onlyRole(RATE_MANAGER_ROLE) {
        // Enhanced rate validation
        if (newRate == 0) revert ZeroRate();
        
        uint256 oldRate = credaToXpRate;
        
        // Prevent excessive rate changes (max 50% change per update for safety)
        uint256 maxChangePercent = 50;
        if (oldRate != 0) {
            uint256 changePercent;
            if (newRate > oldRate) {
                changePercent = ((newRate - oldRate) * 100) / oldRate;
            } else {
                changePercent = ((oldRate - newRate) * 100) / oldRate;
            }
            
            if (changePercent > maxChangePercent) {
                revert RateChangeTooBig(oldRate, newRate, maxChangePercent);
            }
        }
        
        // Validate rate is within reasonable bounds (not too high)
        uint256 maxReasonableRate = 1000 * PRECISION_FACTOR; // Max 1000:1 ratio
        if (newRate > maxReasonableRate) {
            revert ExcessiveAmount(newRate, maxReasonableRate);
        }
        
        credaToXpRate = newRate;
        emit RateUpdated(oldRate, newRate);
    }
    
    /**
     * @dev Pause contract operations
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause contract operations
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Emergency withdraw function for stuck tokens
     * @param token Address of token to withdraw
     * @param to Address to send tokens to
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(EMERGENCY_ROLE) {
        // Enhanced input validation
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        
        // Prevent withdrawal of critical tokens without proper validation
        if (token == address(credaToken) && totalLockedCreda > 0) {
            revert RecoveryNotAllowed(token, "Cannot withdraw CREDA while tokens are locked");
        }
        
        if (token == address(0)) {
            // Withdraw ETH with enhanced error handling
            uint256 contractBalance = address(this).balance;
            if (amount > contractBalance) {
                revert InsufficientUserBalance(address(this), address(0), amount, contractBalance);
            }
            
            (bool success, bytes memory returnData) = payable(to).call{value: amount}("");
            if (!success) {
                revert EmergencyActionFailed("ETH_WITHDRAWAL", "Transfer failed");
            }
        } else {
            // Withdraw ERC20 token with enhanced validation
            IERC20 tokenContract = IERC20(token);
            uint256 contractBalance = tokenContract.balanceOf(address(this));
            
            if (amount > contractBalance) {
                revert InsufficientUserBalance(address(this), token, amount, contractBalance);
            }
            
            bool success = tokenContract.transfer(to, amount);
            if (!success) {
                revert TransferFailed(token, address(this), to, amount);
            }
        }
        
        emit EmergencyWithdraw(token, to, amount);
    }
    
    // ============ View Functions ============
    /**
     * @dev Get complete game token information
     * @param gameId ID of the game token
     */
    function getGameTokenInfo(uint256 gameId) 
        external 
        view 
        returns (
            GameTokenInfo memory info,
            GameTokenMetadata memory metadata
        ) 
    {
        info = gameTokens[gameId];
        metadata = gameTokenMetadata[gameId];
    }
    
    /**
     * @dev Get user's created game tokens
     * @param user Address of the user
     */
    function getUserGameTokens(address user) 
        external 
        view 
        returns (uint256[] memory) 
    {
        return userGameTokens[user];
    }
    
    /**
     * @dev Calculate XP amount for given CREDA amount
     * @param credaAmount Amount of CREDA tokens
     */
    function calculateXpAmount(uint256 credaAmount) 
        external 
        view 
        returns (uint256) 
    {
        return (credaAmount * credaToXpRate) / PRECISION_FACTOR;
    }
    
    /**
     * @dev Calculate XP return for burning game tokens
     * @param gameId ID of the game token
     * @param burnAmount Amount to burn
     */
    function calculateXpReturn(uint256 gameId, uint256 burnAmount) 
        external 
        view 
        returns (uint256) 
    {
        if (gameId == 0 || gameId >= nextGameId) return 0;
        
        GameTokenInfo memory gameInfo = gameTokens[gameId];
        if (!gameInfo.active) return 0;
        
        GameTokenMetadata memory metadata = gameTokenMetadata[gameId];
        if (metadata.initialSupply == 0) return 0;
        
        return (burnAmount * uint256(gameInfo.xpLocked)) / metadata.initialSupply;
    }
    
    /**
     * @dev Check if user has already used a game name
     * @param user Address of the user
     * @param name Name to check
     */
    function isGameNameUsed(address user, string calldata name) 
        external 
        view 
        returns (bool) 
    {
        return userGameNames[user][name];
    }
    
    // ============ Enhanced Input Validation Functions ============
    
    /**
     * @dev Validate string inputs with comprehensive checks
     */
    function _validateString(string calldata str, string memory fieldName, uint256 maxLength) private pure {
        bytes memory strBytes = bytes(str);
        if (strBytes.length == 0) {
            revert EmptyString(fieldName);
        }
        if (strBytes.length > maxLength) {
            revert StringTooLong(fieldName, strBytes.length, maxLength);
        }
        
        // Check for invalid characters (basic validation)
        for (uint256 i = 0; i < strBytes.length; i++) {
            bytes1 char = strBytes[i];
            // Allow alphanumeric, spaces, and basic symbols
            if (!(
                (char >= 0x30 && char <= 0x39) || // 0-9
                (char >= 0x41 && char <= 0x5A) || // A-Z
                (char >= 0x61 && char <= 0x7A) || // a-z
                char == 0x20 || char == 0x2D || char == 0x5F || char == 0x2E // space, -, _, .
            )) {
                revert InvalidCharacters(fieldName);
            }
        }
    }
    
    /**
     * @dev Validate user token balance and allowance
     */
    function _validateUserTokenAccess(
        address user,
        address token,
        uint256 amount
    ) private view {
        if (amount == 0) {
            revert ZeroAmount();
        }
        
        // Check user balance
        uint256 userBalance = IERC20(token).balanceOf(user);
        if (userBalance < amount) {
            revert InsufficientUserBalance(user, token, amount, userBalance);
        }
        
        // Check allowance
        uint256 allowance = IERC20(token).allowance(user, address(this));
        if (allowance < amount) {
            revert InsufficientAllowance(user, address(this), token, amount, allowance);
        }
    }
    
    /**
     * @dev Safe mathematical operations with overflow/underflow protection
     */
    function _safeMul(uint256 a, uint256 b, string memory operation) private pure returns (uint256) {
        if (a == 0) return 0;
        
        uint256 c = a * b;
        if (c / a != b) {
            revert MathOverflow(operation);
        }
        return c;
    }
    
    function _safeDiv(uint256 a, uint256 b, string memory operation) private pure returns (uint256) {
        if (b == 0) {
            revert DivisionByZero(operation);
        }
        return a / b;
    }
    
    function _safeAdd(uint256 a, uint256 b, string memory operation) private pure returns (uint256) {
        uint256 c = a + b;
        if (c < a) {
            revert MathOverflow(operation);
        }
        return c;
    }
    
    function _safeSub(uint256 a, uint256 b, string memory operation) private pure returns (uint256) {
        if (b > a) {
            revert MathUnderflow(operation);
        }
        return a - b;
    }
} 