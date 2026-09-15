// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ETHS - Synthetic Ether
 * @notice Synthetic ETH minted by Bridge, burned on redemption
 * @dev Only BridgeCore can mint/burn. Value tracked via oracle.
 */
contract ETHS is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    
    /// @notice Total amount ever minted
    uint256 public totalMinted;
    
    /// @notice Total amount ever burned
    uint256 public totalBurned;
    
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    
    constructor() ERC20("Synthetic Ether", "ETHS") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BRIDGE_ROLE, msg.sender);
    }
    
    /**
     * @notice Mint ETHS to address (only Bridge)
     */
    function mint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _mint(to, amount);
        totalMinted += amount;
        emit Minted(to, amount);
    }
    
    /**
     * @notice Burn ETHS from address (only Bridge)
     */
    function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _burn(from, amount);
        totalBurned += amount;
        emit Burned(from, amount);
    }
    
    /**
     * @notice Get net supply
     */
    function netSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }
}
