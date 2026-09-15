// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title USDS - Synthetic Dollar
 * @notice Synthetic stablecoin minted by Bridge, burned on redemption
 * @dev Only BridgeCore can mint/burn. Peg maintained via arbitrage cycles.
 */
contract USDS is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    /// @notice Total amount ever minted (for tracking)
    uint256 public totalMinted;
    
    /// @notice Total amount ever burned
    uint256 public totalBurned;
    
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    
    constructor() ERC20("Synthetic Dollar", "USDS") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BRIDGE_ROLE, msg.sender);
    }
    
    /**
     * @notice Mint USDS to address (only Bridge)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _mint(to, amount);
        totalMinted += amount;
        emit Minted(to, amount);
    }
    
    /**
     * @notice Burn USDS from address (only Bridge)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _burn(from, amount);
        totalBurned += amount;
        emit Burned(from, amount);
    }
    
    /**
     * @notice Get net supply (minted - burned)
     */
    function netSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }
}
