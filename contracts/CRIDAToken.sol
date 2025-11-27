// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CRIDAToken
 * @dev CRIDA Token - Base token that users lock to receive XP tokens
 */
contract CRIDAToken is ERC20, Ownable {
    
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18; // 1 billion tokens
    
    constructor(
        address owner
    ) ERC20("CRIDA Token", "CRIDA") Ownable(owner) {
        _mint(owner, INITIAL_SUPPLY);
    }
    
    /**
     * @dev Mint additional tokens (for testing or future needs)
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
} 