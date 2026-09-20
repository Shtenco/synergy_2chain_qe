// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./SyntheticTokensV2.sol";
import "./IExternalPriceOracleV2.sol";

/// @notice Solvent 1:1 transmutation layer.
/// @dev Solvency is based on ACTUAL canonical balances and synthetic totalSupply,
///      so donations/equity reserves count and accounting counters cannot hide deficits.
contract BridgeCoreV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    uint256 public constant BPS = 10_000;
    uint256 public constant PRICE_6D_TO_18 = 1e12;

    USDSV2 public immutable usds;
    ETHSV2 public immutable eths;
    IERC20 public immutable canonicalUSDC;
    IExternalPriceOracleV2 public immutable oracle;
    uint256 public immutable usdcScale;

    bool public emergencyStopped;
    uint256 public minSolvencyBps = BPS;

    event Locked(address indexed user, uint256 canonicalAmount, bool isETH);
    event Redeemed(address indexed user, uint256 syntheticAmount, bool isETH);
    event EquityUSDCDeposited(address indexed from, uint256 canonicalAmount);
    event EquityETHDeposited(address indexed from, uint256 amount);
    event EmergencyState(bool stopped);
    event MinimumSolvencyUpdated(uint256 bps);

    error EmergencyStopped();
    error ZeroAmount();
    error IncorrectETHValue(uint256 sent, uint256 expected);
    error Insolvent(uint256 assets18, uint256 liabilities18);
    error InsufficientAssetLiquidity();
    error StaleOracle();

    constructor(
        address _usds,
        address _eths,
        address _canonicalUSDC,
        address _oracle
    ) {
        require(
            _usds != address(0) && _eths != address(0) &&
            _canonicalUSDC != address(0) && _oracle != address(0),
            "zero address"
        );
        usds = USDSV2(_usds);
        eths = ETHSV2(_eths);
        canonicalUSDC = IERC20(_canonicalUSDC);
        oracle = IExternalPriceOracleV2(_oracle);

        uint8 d = IERC20Metadata(_canonicalUSDC).decimals();
        require(d <= 18, "USDC decimals");
        usdcScale = 10 ** (18 - d);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    modifier live() {
        if (emergencyStopped) revert EmergencyStopped();
        if (oracle.isStale()) revert StaleOracle();
        _;
    }

    function lockUSDCAndMintUSDS(address user, uint256 amount)
        external onlyRole(OPERATOR_ROLE) live nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        canonicalUSDC.safeTransferFrom(msg.sender, address(this), amount);
        usds.mint(user, amount * usdcScale);
        _assertSolvent();
        emit Locked(user, amount, false);
    }

    function lockETHAndMintETHS(address user, uint256 amount)
        external payable onlyRole(OPERATOR_ROLE) live nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (msg.value != amount) revert IncorrectETHValue(msg.value, amount);
        eths.mint(user, amount);
        _assertSolvent();
        emit Locked(user, amount, true);
    }

    function burnUSDSAndUnlockUSDC(address user, uint256 amount18)
        external onlyRole(OPERATOR_ROLE) live nonReentrant
    {
        if (amount18 == 0) revert ZeroAmount();
        uint256 payout = amount18 / usdcScale;
        if (payout == 0 || canonicalUSDC.balanceOf(address(this)) < payout) {
            revert InsufficientAssetLiquidity();
        }

        usds.bridgeBurn(msg.sender, amount18);
        canonicalUSDC.safeTransfer(user, payout);
        _assertSolvent();
        emit Redeemed(user, amount18, false);
    }

    function burnETHSAndUnlockETH(address user, uint256 amount)
        external onlyRole(OPERATOR_ROLE) live nonReentrant
    {
        if (amount == 0) revert ZeroAmount();
        if (address(this).balance < amount) revert InsufficientAssetLiquidity();

        eths.bridgeBurn(msg.sender, amount);
        (bool ok,) = user.call{value: amount}("");
        require(ok, "ETH transfer");
        _assertSolvent();
        emit Redeemed(user, amount, true);
    }

    /// @notice Genuine equity reserve: actual canonical asset enters the bridge.
    function depositEquityUSDC(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        canonicalUSDC.safeTransferFrom(msg.sender, address(this), amount);
        emit EquityUSDCDeposited(msg.sender, amount);
    }

    function depositEquityETH() external payable {
        if (msg.value == 0) revert ZeroAmount();
        emit EquityETHDeposited(msg.sender, msg.value);
    }

    function hardAssets18() public view returns (uint256) {
        uint256 p6 = oracle.getPrice6d();
        return
            canonicalUSDC.balanceOf(address(this)) * usdcScale +
            (address(this).balance * p6 * PRICE_6D_TO_18) / 1e18;
    }

    function liabilities18() public view returns (uint256) {
        uint256 p6 = oracle.getPrice6d();
        return
            usds.totalSupply() +
            (eths.totalSupply() * p6 * PRICE_6D_TO_18) / 1e18;
    }

    function solvencyBps() public view returns (uint256) {
        uint256 l = liabilities18();
        return l == 0 ? type(uint256).max : hardAssets18() * BPS / l;
    }

    function usdsLCRBps() public view returns (uint256) {
        uint256 l = usds.totalSupply();
        return l == 0 ? type(uint256).max :
            canonicalUSDC.balanceOf(address(this)) * usdcScale * BPS / l;
    }

    function ethsLCRBps() public view returns (uint256) {
        uint256 l = eths.totalSupply();
        return l == 0 ? type(uint256).max : address(this).balance * BPS / l;
    }

    function assertSupplyInvariant() external view returns (bool) {
        // A single BRIDGE_ROLE holder must be enforced at deployment/governance.
        // This invariant makes any hidden mint immediately visible in liabilities.
        return usds.netSupply() == usds.totalSupply() &&
               eths.netSupply() == eths.totalSupply();
    }

    function setMinimumSolvencyBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(bps >= BPS, "below 100%");
        minSolvencyBps = bps;
        emit MinimumSolvencyUpdated(bps);
    }

    function triggerEmergencyStop() external onlyRole(EMERGENCY_ROLE) {
        emergencyStopped = true;
        emit EmergencyState(true);
    }

    function liftEmergencyStop() external onlyRole(EMERGENCY_ROLE) {
        _assertSolvent();
        emergencyStopped = false;
        emit EmergencyState(false);
    }

    function _assertSolvent() internal view {
        uint256 a = hardAssets18();
        uint256 l = liabilities18();
        if (l != 0 && a * BPS < l * minSolvencyBps) revert Insolvent(a, l);
    }

    receive() external payable {}
}
