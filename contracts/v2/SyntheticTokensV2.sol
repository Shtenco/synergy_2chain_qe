// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

abstract contract BridgeSyntheticV2 is ERC20, AccessControl {
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    uint256 public totalMinted;
    uint256 public totalBurned;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        // The deployer is ADMIN only. It is deliberately NOT a minter.
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _mint(to, amount);
        totalMinted += amount;
    }

    function bridgeBurn(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        _burn(from, amount);
        totalBurned += amount;
    }

    function netSupply() external view returns (uint256) {
        return totalSupply();
    }
}

contract USDSV2 is BridgeSyntheticV2 {
    constructor() BridgeSyntheticV2("Synthetic Dollar V2", "USDS2") {}
}

contract ETHSV2 is BridgeSyntheticV2 {
    constructor() BridgeSyntheticV2("Synthetic Ether V2", "ETHS2") {}
}
