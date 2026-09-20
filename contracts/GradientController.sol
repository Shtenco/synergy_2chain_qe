// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./ManagedOracle.sol";

/**
 * @title GradientController - Keeper-driven gradient updates
 * @notice Translates an observed external (donor) quote into a bounded oracle gradient,
 *         so the system mode reflects the harvestable direction:
 *         donor quote < external  -> negative gradient -> UNDERPRICE (Cycle A direction)
 *         donor quote > external  -> positive gradient -> OVERPRICE (Cycle B direction)
 *         donor quote ~= external -> zero gradient     -> NEUTRAL (stand down)
 *
 * @dev Disclosed economics: update() moves NO funds and creates NO value. It only
 *      switches the mode gate. Growth comes exclusively from harvesting a real
 *      external mispricing afterwards; as the donor converges, the gradient
 *      decays to zero and harvesting stops by itself.
 */
contract GradientController is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant MAX_QUOTE_AGE = 900; // 15 minutes

    ManagedOracle public immutable oracle;

    event GradientUpdated(int256 gradient, uint8 mode, uint256 foreignPrice, uint256 externalPrice);

    error ZeroPrice();
    error StaleForeignQuote(uint256 quoteTimestamp, uint256 blockTimestamp);

    constructor(address _oracle) {
        oracle = ManagedOracle(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
    }

    /**
     * @notice Refresh the gradient from a keeper-supplied donor quote.
     * @param foreignPrice6d Best observed donor quote for ETH, 6 decimals.
     * @param quoteTimestamp When the quote was observed (freshness enforced).
     * @return gradient Applied gradient, clamped to ±maxGradientBps.
     * @return mode Resulting oracle mode (0=UNDERPRICE, 1=OVERPRICE, 2=NEUTRAL).
     */
    function update(uint256 foreignPrice6d, uint256 quoteTimestamp)
        external
        onlyRole(KEEPER_ROLE)
        returns (int256 gradient, uint8 mode)
    {
        if (foreignPrice6d == 0) revert ZeroPrice();
        if (block.timestamp > quoteTimestamp + MAX_QUOTE_AGE) {
            revert StaleForeignQuote(quoteTimestamp, block.timestamp);
        }

        uint256 ext = oracle.getExternalPrice();
        int256 dev = (int256(foreignPrice6d) - int256(ext)) * 10000 / int256(ext);

        (gradient, mode) = _apply(dev, foreignPrice6d, ext);
    }

    /**
     * @notice Refresh the gradient from a keeper-computed CROSS-VENUE spread.
     * @dev Corrected semantics (disclosed): the spread is
     *      spreadBps = (internalPoolPrice - foreignPrice) / foreignPrice.
     *      spread > +200  -> OVERPRICE (internal rich: sell internal, buy foreign).
     *      spread < -200  -> UNDERPRICE (internal cheap: buy internal, sell foreign).
     *      Otherwise      -> NEUTRAL (converged: stand down).
     *      The legacy "Cycle A = UNDERPRICE" mapping was backwards: you harvest
     *      by selling where RICH, not where cheap.
     * @param spreadBps Cross-venue spread in basis points (signed).
     * @param quoteTimestamp When the underlying quotes were observed (freshness enforced).
     */
    function updateSpread(int256 spreadBps, uint256 quoteTimestamp)
        external
        onlyRole(KEEPER_ROLE)
        returns (int256 gradient, uint8 mode)
    {
        if (block.timestamp > quoteTimestamp + MAX_QUOTE_AGE) {
            revert StaleForeignQuote(quoteTimestamp, block.timestamp);
        }
        (gradient, mode) = _apply(spreadBps, 0, oracle.getExternalPrice());
    }

    function _apply(int256 dev, uint256 foreignPrice, uint256 ext)
        internal
        returns (int256 gradient, uint8 mode)
    {
        int256 maxG = oracle.maxGradientBps();
        if (dev > maxG) dev = maxG;
        if (dev < -maxG) dev = -maxG;

        oracle.setGradient(dev);

        gradient = dev;
        mode = oracle.getMode();
        emit GradientUpdated(gradient, mode, foreignPrice, ext);
    }
}
