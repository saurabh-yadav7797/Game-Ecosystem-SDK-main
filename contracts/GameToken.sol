// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GameToken
 * @dev Optimized ERC-20 game token with enhanced security
 * Each game gets its own instance of this contract
 * Optimized for gas efficiency while maintaining security
 */
contract GameToken is ERC20, Ownable, ReentrancyGuard {
    // ============ Immutable Variables (Gas Optimized) ============
    uint8 private immutable _decimals;
    address public immutable factory; // Factory contract that deployed this token
    uint256 public immutable gameId; // Unique game identifier
    
    // ============ State Variables ============
    uint256 public totalBurned; // Track total burned for analytics
    bool public burnEnabled = true; // Emergency disable burning
    
    // ============ Minting Protection ============
    
    // State to track if initial minting is complete
    bool private _initialMintComplete;
    
    // ============ Events ============
    event TokensBurned(address indexed user, uint256 amount, uint256 totalBurned);
    event BurnStatusChanged(bool enabled);
    
    // ============ Comprehensive Error Definitions ============
    // Input Validation Errors
    error ZeroAmount();
    error ZeroAddress();
    error InvalidAddress(address provided, string reason);
    error InvalidAmount(uint256 provided, uint256 min, uint256 max);
    
    // Access Control Errors
    error UnauthorizedFactory(address caller, address expectedFactory);
    error UnauthorizedOwner(address caller, address expectedOwner);
    error UnauthorizedBurner(address caller);
    
    // Contract State Errors
    error BurnDisabled(string reason);
    error ContractPaused();
    error InvalidContractState(string reason);
    error ReentrancyDetected();
    
    // Balance and Supply Errors
    error InsufficientBalance(address account, uint256 required, uint256 available);
    error ExcessiveBurnRequest(uint256 requested, uint256 maxAllowed);
    error InvalidBurnAmount(uint256 amount, string reason);
    
    // Business Logic Errors
    error MintingDisabledAfterInit(string reason);
    error BurningOperationFailed(address from, uint256 amount, string reason);
    error TransferOperationFailed(address from, address to, uint256 amount);
    error GameTokenInactive(uint256 gameId);
    error InvalidGameOperation(string operation, string reason);
    
    // Mathematical Errors
    error MathOverflow(string operation);
    error MathUnderflow(string operation);
    
    // Recovery Errors
    error RecoveryFailed(address token, string reason);
    error InvalidRecoveryTarget(address target);
    error RecoveryNotAllowed(string reason);
    
    // ============ Modifiers ============
    modifier onlyFactory() {
        if (msg.sender != factory) revert UnauthorizedBurner(msg.sender);
        _;
    }
    
    modifier burnAllowed() {
        if (!burnEnabled) revert BurnDisabled("Burning is disabled");
        _;
    }
    
    // ============ Constructor ============
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint256 initialSupply,
        address owner,
        address factory_,
        uint256 gameId_
    ) ERC20(name, symbol) Ownable(owner) {
        // Comprehensive input validation
        if (bytes(name).length == 0) {
            revert InvalidAddress(address(0), "Token name cannot be empty");
        }
        if (bytes(symbol).length == 0) {
            revert InvalidAddress(address(0), "Token symbol cannot be empty");
        }
        if (owner == address(0)) {
            revert ZeroAddress();
        }
        if (factory_ == address(0)) {
            revert ZeroAddress();
        }
        if (decimals_ > 18) {
            revert InvalidAmount(decimals_, 0, 18);
        }
        if (initialSupply == 0) {
            revert ZeroAmount();
        }
        if (owner == factory_) {
            revert InvalidContractState("Owner and factory cannot be the same");
        }
        
        _decimals = decimals_;
        factory = factory_;
        gameId = gameId_;
        
        // Mint initial supply directly to owner - simplified for deployment success
        _mint(owner, initialSupply);
        _initialMintComplete = true;
    }
    
    // ============ View Functions ============
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
    
    // ============ Burn Functions ============
    /**
     * @dev Burn tokens from a specific account (called by factory)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) 
        external 
        onlyFactory 
        burnAllowed 
        nonReentrant 
    {
        // Enhanced input validation
        if (from == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        
        uint256 userBalance = balanceOf(from);
        if (userBalance < amount) {
            revert InsufficientBalance(from, amount, userBalance);
        }
        
        // Validate burn amount isn't excessive (no more than total supply)
        if (amount > totalSupply()) {
            revert ExcessiveBurnRequest(amount, totalSupply());
        }
        
        // Additional security check - prevent burning more than reasonable limit per transaction
        uint256 maxBurnPerTx = totalSupply() / 10; // Max 10% of supply per transaction
        if (amount > maxBurnPerTx) {
            revert InvalidBurnAmount(amount, "Exceeds maximum burn per transaction");
        }
        
        // Update total burned before burning (for reentrancy safety)
        totalBurned += amount;
        
        try this._performBurn(from, amount) {
            emit TokensBurned(from, amount, totalBurned);
        } catch Error(string memory reason) {
            // Revert total burned update if burn fails
            totalBurned -= amount;
            revert BurningOperationFailed(from, amount, reason);
        } catch {
            // Revert total burned update if burn fails
            totalBurned -= amount;
            revert BurningOperationFailed(from, amount, "Unknown burn error");
        }
    }
    
    /**
     * @dev Internal burn function for error handling separation
     */
    function _performBurn(address from, uint256 amount) external {
        require(msg.sender == address(this), "Only self-call allowed");
        _burn(from, amount);
    }
    
    /**
     * @dev Allow users to burn their own tokens directly
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) external burnAllowed nonReentrant {
        // Enhanced input validation
        if (amount == 0) {
            revert ZeroAmount();
        }
        
        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance < amount) {
            revert InsufficientBalance(msg.sender, amount, userBalance);
        }
        
        // Update total burned and perform burn
        totalBurned += amount;
        
        try this._performBurn(msg.sender, amount) {
            emit TokensBurned(msg.sender, amount, totalBurned);
        } catch Error(string memory reason) {
            // Revert total burned update if burn fails
            totalBurned -= amount;
            revert BurningOperationFailed(msg.sender, amount, reason);
        } catch {
            // Revert total burned update if burn fails
            totalBurned -= amount;
            revert BurningOperationFailed(msg.sender, amount, "Unknown burn error");
        }
    }
    
    // ============ Admin Functions ============
    /**
     * @dev Enable/disable burning (emergency control)
     * @param enabled Whether burning should be enabled
     */
    function setBurnEnabled(bool enabled) external onlyOwner {
        burnEnabled = enabled;
        emit BurnStatusChanged(enabled);
    }
    
    /**
     * @dev Emergency function to recover stuck tokens
     * @param token Address of token to recover (address(0) for ETH)
     * @param to Address to send recovered tokens
     * @param amount Amount to recover
     */
    function emergencyRecover(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        
        if (token == address(0)) {
            // Recover ETH
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Recover ERC20 tokens
            IERC20(token).transfer(to, amount);
        }
    }
    
    /**
     * @dev Restricted mint function - only callable by factory
     * This ensures tokens can only be created when XP is properly locked
     */
    function factoryMint(address to, uint256 amount) external onlyFactory {
        // Factory can mint even after initial mint is complete
        // This represents XP being locked for additional tokens
        _mint(to, amount);
    }
    
    /**
     * @dev Block any attempts to call mint functions directly
     * Prevents manual token creation outside the XP locking mechanism
     */
    function mint(address) external pure {
        revert("Mint disabled: use factory to lock XP");
    }
} 