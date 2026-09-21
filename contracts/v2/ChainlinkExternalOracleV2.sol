// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IExternalPriceOracleV2.sol";

interface IChainlinkAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        );
}

/// @notice Minimal Chainlink adapter normalized to 6-decimal USD.
/// @dev Feed address is injected at deployment; no chain-specific address is hard-coded.
contract ChainlinkExternalOracleV2 is IExternalPriceOracleV2 {
    IChainlinkAggregatorV3 public immutable feed;
    uint256 public immutable maxAge;
    uint8 public immutable feedDecimals;

    error InvalidFeed();
    error InvalidAnswer();
    error StalePrice(uint256 updatedAt_, uint256 nowTs);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);

    constructor(address _feed, uint256 _maxAge) {
        if (_feed == address(0) || _maxAge == 0) revert InvalidFeed();
        feed = IChainlinkAggregatorV3(_feed);
        maxAge = _maxAge;
        feedDecimals = feed.decimals();
    }

    function _read() internal view returns (uint256 price6d, uint256 ts) {
        (uint80 roundId, int256 answer, , uint256 updatedAt_, uint80 answeredInRound) =
            feed.latestRoundData();

        if (answer <= 0 || updatedAt_ == 0) revert InvalidAnswer();
        if (answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);
        if (block.timestamp > updatedAt_ + maxAge) {
            revert StalePrice(updatedAt_, block.timestamp);
        }

        uint256 raw = uint256(answer);
        if (feedDecimals == 6) {
            price6d = raw;
        } else if (feedDecimals > 6) {
            price6d = raw / (10 ** (feedDecimals - 6));
        } else {
            price6d = raw * (10 ** (6 - feedDecimals));
        }

        if (price6d == 0) revert InvalidAnswer();
        ts = updatedAt_;
    }

    function getPrice6d() external view override returns (uint256) {
        (uint256 p, ) = _read();
        return p;
    }

    function isStale() external view override returns (bool) {
        (, , , uint256 ts, ) = feed.latestRoundData();
        return ts == 0 || block.timestamp > ts + maxAge;
    }

    function updatedAt() external view override returns (uint256) {
        (, , , uint256 ts, ) = feed.latestRoundData();
        return ts;
    }
}
