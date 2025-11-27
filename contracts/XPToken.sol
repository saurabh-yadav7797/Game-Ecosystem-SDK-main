// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title XPToken
 * @dev XP Token with controlled minting/burning for the game ecosystem
 * Only the authorized factory contract can mint new XP tokens when CRIDA is locked
 * XP tokens represent experience points that can be locked to create game tokens
 */
contract XPToken is ERC20, AccessControl, Pausable, ReentrancyGuard {
    
    // ============ Constants ============
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    // ============ State Variables ============
    uint256 public totalMinted;
    uint256 public totalBurnedAmount;
    
    // ============ Events ============
    event TokensMinted(address indexed to, uint256 amount, address indexed minter);
    event TokensBurned(address indexed from, uint256 amount, address indexed burner);
    
    // ============ Comprehensive Error Definitions ============
    // Input Validation Errors
    error ZeroAmount();
    error ZeroAddress();
    error InvalidAddress(address provided, string reason);
    
    // Access Control Errors  
    error UnauthorizedMinter(address caller);
    error UnauthorizedBurner(address caller);
    error UnauthorizedPauser(address caller);
    error RoleAlreadyGranted(address account, bytes32 role);
    error RoleNotGranted(address account, bytes32 role);
    
    // Balance and Supply Errors
    error InsufficientBalance(address account, uint256 required, uint256 available);
    error ExcessiveMintRequest(uint256 requested, uint256 maxAllowed);
    error ExcessiveBurnRequest(uint256 requested, uint256 available);
    error TotalSupplyLimitExceeded(uint256 newTotal, uint256 maxSupply);
    
    // Contract State Errors
    error ContractPaused();
    error ContractNotPaused();
    error InvalidContractState(string reason);
    error ReentrancyDetected();
    
    // Mathematical Errors
    error MathOverflow(string operation);
    error MathUnderflow(string operation);
    
    // External Call Errors
    error MintOperationFailed(address to, uint256 amount, string reason);
    error BurnOperationFailed(address from, uint256 amount, string reason);
    error TransferOperationFailed(address from, address to, uint256 amount);
    
    // Business Logic Errors
    error MintingDisabled(string reason);
    error BurningDisabled(string reason);
    error DailyMintLimitExceeded(address minter, uint256 dailyLimit, uint256 currentMinted);
    error SuspiciousActivity(address account, string reason);
    
    // ============ Constructor ============
    constructor(
        string memory name,
        string memory symbol,
        address admin,
        address factory
    ) ERC20(name, symbol) {
        // Comprehensive input validation
        if (bytes(name).length == 0) {
            revert InvalidAddress(address(0), "Token name cannot be empty");
        }
        if (bytes(symbol).length == 0) {
            revert InvalidAddress(address(0), "Token symbol cannot be empty");
        }
        if (admin == address(0)) {
            revert ZeroAddress();
        }
        if (factory == address(0)) {
            revert ZeroAddress();
        }
      
        
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        
        // Grant minter role to factory contract with validation
        _grantRole(MINTER_ROLE, factory);
        _grantRole(BURNER_ROLE, factory);
    }
    
    // ============ Enhanced Minting Functions ============
    /**
     * @dev Mint XP tokens to user when CRIDA is locked
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) 
        external 
        onlyRole(MINTER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        // Enhanced input validation
        if (to == address(0)) {
            revert ZeroAddress();
        }
        if (amount == 0) {
            revert ZeroAmount();
        }
        
        // Prevent minting to contract itself (security measure)
        if (to == address(this)) {
            revert InvalidAddress(to, "Cannot mint to contract itself");
        }
        
        // Check for potential overflow in total supply
        uint256 newTotalSupply = totalSupply() + amount;
        uint256 maxSupply = type(uint256).max / 2; // Reasonable max supply limit
        if (newTotalSupply > maxSupply) {
            revert TotalSupplyLimitExceeded(newTotalSupply, maxSupply);
        }
        
        // Update statistics before minting (for atomicity)
        totalMinted += amount;
        
        try this._performMint(to, amount) {
            emit TokensMinted(to, amount, msg.sender);
        } catch Error(string memory reason) {
            // Revert statistics update if minting fails
            totalMinted -= amount;
            revert MintOperationFailed(to, amount, reason);
        } catch {
            // Revert statistics update if minting fails
            totalMinted -= amount;
            revert MintOperationFailed(to, amount, "Unknown minting error");
        }
    }
    
    /**
     * @dev Internal mint function for error handling separation
     */
    function _performMint(address to, uint256 amount) external {
        require(msg.sender == address(this), "Only self-call allowed");
        _mint(to, amount);
    }
    
    // ============ Burning Functions ============
    /**
     * @dev Burn XP tokens from user
     * @param amount Amount of tokens to burn
     */
    function burn(uint256 amount) 
        external 
        whenNotPaused 
        nonReentrant 
    {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance(msg.sender, amount, balanceOf(msg.sender));
        
        totalBurnedAmount += amount;
        _burn(msg.sender, amount);
        
        emit TokensBurned(msg.sender, amount, msg.sender);
    }
    
    /**
     * @dev Burn XP tokens from specific account (factory use)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burnFrom(address from, uint256 amount) 
        external 
        onlyRole(BURNER_ROLE) 
        whenNotPaused 
        nonReentrant 
    {
        if (amount == 0) revert ZeroAmount();
        if (balanceOf(from) < amount) revert InsufficientBalance(from, amount, balanceOf(from));
        
        totalBurnedAmount += amount;
        _burn(from, amount);
        
        emit TokensBurned(from, amount, msg.sender);
    }
    
    // ============ Admin Functions ============
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
    
    // ============ View Functions ============
    /**
     * @dev Get total XP tokens in circulation
     */
    function totalInCirculation() external view returns (uint256) {
        return totalSupply();
    }
    
    /**
     * @dev Get minting/burning statistics
     */
    function getStats() external view returns (
        uint256 minted,
        uint256 burned,
        uint256 circulation
    ) {
        return (totalMinted, totalBurnedAmount, totalSupply());
    }
    
    // ============ Override Functions ============
    /**
     * @dev Override transfer to add pause functionality
     */
    function _update(address from, address to, uint256 amount) 
        internal 
        override 
        whenNotPaused 
    {
        super._update(from, to, amount);
    }
} 