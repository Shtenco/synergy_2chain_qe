// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IExternalPriceOracleV2.sol";

/// @notice Consolidated balance sheet that refuses to count synthetic tokens,
///         protocol LP tokens, internal oracle marks, or internal TVL as hard assets.
/// @dev Liabilities are deliberately conservative: ALL USDS/ETHS totalSupply is counted.
contract EconomicLedgerV2 is Ownable {
    uint256 public constant BPS = 10_000;
    uint256 public constant PRICE_6D_TO_18 = 1e12;

    IERC20 public immutable canonicalUSDC;
    IERC20 public immutable weth;
    IERC20 public immutable usds;
    IERC20 public immutable eths;
    IExternalPriceOracleV2 public immutable externalOracle;

    address public immutable bridge;
    uint256 public immutable usdcScale;

    address[] private _tracked;
    mapping(address => bool) public isTracked;

    event AccountTrackingUpdated(address indexed account, bool tracked);

    constructor(
        address _canonicalUSDC,
        address _weth,
        address _usds,
        address _eths,
        address _externalOracle,
        address _bridge,
        address[] memory initialTracked
    ) {
        require(
            _canonicalUSDC != address(0) &&
            _weth != address(0) &&
            _usds != address(0) &&
            _eths != address(0) &&
            _externalOracle != address(0) &&
            _bridge != address(0),
            "zero address"
        );

        canonicalUSDC = IERC20(_canonicalUSDC);
        weth = IERC20(_weth);
        usds = IERC20(_usds);
        eths = IERC20(_eths);
        externalOracle = IExternalPriceOracleV2(_externalOracle);
        bridge = _bridge;

        uint8 d = IERC20Metadata(_canonicalUSDC).decimals();
        require(d <= 18, "USDC decimals");
        usdcScale = 10 ** (18 - d);

        _track(_bridge);
        for (uint256 i = 0; i < initialTracked.length; i++) {
            _track(initialTracked[i]);
        }
    }

    receive() external payable {}

    function trackedAccounts() external view returns (address[] memory) {
        return _tracked;
    }

    function addTrackedAccount(address account) external onlyOwner {
        _track(account);
    }

    function _track(address account) internal {
        require(account != address(0), "account=0");
        if (isTracked[account]) return;
        isTracked[account] = true;
        _tracked.push(account);
        emit AccountTrackingUpdated(account, true);
    }

    /// @notice Real external assets only, normalized to 18-decimal USD.
    function hardAssets18() public view returns (uint256 value) {
        uint256 p6 = externalOracle.getPrice6d();

        for (uint256 i = 0; i < _tracked.length; i++) {
            address a = _tracked[i];
            value += canonicalUSDC.balanceOf(a) * usdcScale;
            value += (weth.balanceOf(a) * p6 * PRICE_6D_TO_18) / 1e18;
            value += (a.balance * p6 * PRICE_6D_TO_18) / 1e18;
        }
    }

    /// @notice Redeemable synthetic claims, normalized to 18-decimal USD.
    function liabilities18() public view returns (uint256 value) {
        uint256 p6 = externalOracle.getPrice6d();
        value = usds.totalSupply();
        value += (eths.totalSupply() * p6 * PRICE_6D_TO_18) / 1e18;
    }

    function hardNAV18() public view returns (int256) {
        return int256(hardAssets18()) - int256(liabilities18());
    }

    function usdsLCRBps() public view returns (uint256) {
        uint256 liability = usds.totalSupply();
        if (liability == 0) return type(uint256).max;
        uint256 redeemable = canonicalUSDC.balanceOf(bridge) * usdcScale;
        return (redeemable * BPS) / liability;
    }

    function ethsLCRBps() public view returns (uint256) {
        uint256 liability = eths.totalSupply();
        if (liability == 0) return type(uint256).max;
        return (bridge.balance * BPS) / liability;
    }

    function solvencyBps() public view returns (uint256) {
        uint256 l = liabilities18();
        if (l == 0) return type(uint256).max;
        return (hardAssets18() * BPS) / l;
    }

    function snapshot()
        external
        view
        returns (
            uint256 hardAssets,
            uint256 liabilities,
            int256 hardNAV,
            uint256 usdsLCR,
            uint256 ethsLCR,
            uint256 solvency
        )
    {
        hardAssets = hardAssets18();
        liabilities = liabilities18();
        hardNAV = int256(hardAssets) - int256(liabilities);
        usdsLCR = usdsLCRBps();
        ethsLCR = ethsLCRBps();
        solvency = liabilities == 0 ? type(uint256).max : (hardAssets * BPS) / liabilities;
    }
}
