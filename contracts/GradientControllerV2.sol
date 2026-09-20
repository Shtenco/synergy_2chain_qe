// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./ManagedOracle.sol";

/**
 * @title GradientControllerV2 - Stage 2 of the ТЗ: multi-venue routing + halt automaton
 * @notice Extends the V1 keeper-gradient design:
 *         - updateRoute(): keeper submits cross-venue spreads for N donors; the
 *           venue with the LARGEST |spread| wins (ties keep the first). Gradient
 *           is clamped to ±maxGradientBps and the mode gate follows it.
 *         - HALT/STANDBY automaton: halted flag blocks harvesting via
 *           harvestAllowed() even when a spread exists. resume() reopens.
 *         - Depeg guard: reportDepeg() auto-halts when the USDS peg deviates
 *           more than 2% from $1 (keeper-supplied quote, freshness enforced).
 *
 * @dev Disclosed economics (unchanged from V1): updates move no funds and create
 *      no value. Growth comes only from harvesting real external mispricings.
 */
contract GradientControllerV2 is AccessControl {
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant HALT_ROLE = keccak256("HALT_ROLE");

    uint256 public constant MAX_QUOTE_AGE = 900; // 15 minutes
    uint256 public constant DEPEG_BPS = 200; // 2% peg band
    uint256 public constant PEG_6D = 1e6; // $1.00 in 6 decimals

    ManagedOracle public immutable oracle;

    bool public halted;
    string public haltReason;

    event RouteUpdated(int256 gradient, uint8 mode, uint256 venueIndex, int256 spreadBps);
    event Halted(string reason);
    event Resumed();
    event DepegReported(uint256 usdsPrice6d, bool breached);

    error ZeroPrice();
    error StaleQuote(uint256 quoteTimestamp, uint256 blockTimestamp);
    error EmptySpreads();
    error StillHalted();

    constructor(address _oracle) {
        oracle = ManagedOracle(_oracle);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(KEEPER_ROLE, msg.sender);
        _grantRole(HALT_ROLE, msg.sender);
    }

    /**
     * @notice Refresh gradient from N keeper-computed cross-venue spreads.
     * @param spreadsBps Per-venue spreads, (internalPool - venue)/venue in bps.
     * @param quoteTimestamp When the underlying quotes were observed.
     * @return gradient Applied gradient (clamped).
     * @return mode Resulting oracle mode (0/1/2).
     * @return venueIndex Winning venue (max |spread|, first wins ties).
     */
    function updateRoute(int256[] calldata spreadsBps, uint256 quoteTimestamp)
        external
        onlyRole(KEEPER_ROLE)
        returns (int256 gradient, uint8 mode, uint256 venueIndex)
    {
        if (spreadsBps.length == 0) revert EmptySpreads();
        if (block.timestamp > quoteTimestamp + MAX_QUOTE_AGE) {
            revert StaleQuote(quoteTimestamp, block.timestamp);
        }

        int256 best = spreadsBps[0];
        venueIndex = 0;
        for (uint256 i = 1; i < spreadsBps.length; i++) {
            if (_abs(spreadsBps[i]) > _abs(best)) {
                best = spreadsBps[i];
                venueIndex = i;
            }
        }

        int256 maxG = oracle.maxGradientBps();
        int256 g = best;
        if (g > maxG) g = maxG;
        if (g < -maxG) g = -maxG;

        oracle.setGradient(g);

        gradient = g;
        mode = oracle.getMode();
        emit RouteUpdated(gradient, mode, venueIndex, best);
    }

    /**
     * @notice Single-venue convenience wrapper (spread already computed off-chain).
     */
    function updateSpread(int256 spreadBps, uint256 quoteTimestamp)
        external
        onlyRole(KEEPER_ROLE)
        returns (int256 gradient, uint8 mode)
    {
        if (block.timestamp > quoteTimestamp + MAX_QUOTE_AGE) {
            revert StaleQuote(quoteTimestamp, block.timestamp);
        }
        int256 maxG = oracle.maxGradientBps();
        int256 g = spreadBps;
        if (g > maxG) g = maxG;
        if (g < -maxG) g = -maxG;
        oracle.setGradient(g);
        gradient = g;
        mode = oracle.getMode();
        emit RouteUpdated(gradient, mode, 0, spreadBps);
    }

    /// @notice Harvest gate: closed when halted OR when the mode is NEUTRAL.
    function harvestAllowed() external view returns (bool allowed, uint8 mode) {
        mode = oracle.getMode();
        allowed = !halted && mode != 2;
    }

    function halt(string calldata reason) external onlyRole(HALT_ROLE) {
        halted = true;
        haltReason = reason;
        emit Halted(reason);
    }

    function resume() external onlyRole(HALT_ROLE) {
        halted = false;
        haltReason = "";
        emit Resumed();
    }

    /**
     * @notice Depeg guard: keeper reports the USDS market price (6 decimals).
     *         Breach of the 2% band auto-halts the system.
     */
    function reportDepeg(uint256 usdsPrice6d, uint256 quoteTimestamp) external onlyRole(KEEPER_ROLE) returns (bool breached) {
        if (usdsPrice6d == 0) revert ZeroPrice();
        if (block.timestamp > quoteTimestamp + MAX_QUOTE_AGE) {
            revert StaleQuote(quoteTimestamp, block.timestamp);
        }
        uint256 dev = usdsPrice6d > PEG_6D ? usdsPrice6d - PEG_6D : PEG_6D - usdsPrice6d;
        breached = dev * 10000 > PEG_6D * DEPEG_BPS;
        emit DepegReported(usdsPrice6d, breached);
        if (breached) {
            halted = true;
            haltReason = "usds depeg";
            emit Halted("usds depeg");
        }
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}
