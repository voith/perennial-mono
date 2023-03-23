// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract ChainlinkTCAPAggregatorV3 {
  struct RoundData {
      uint80 roundId;
      uint80 answeredInRound;
      int256 answer;
      uint256 startedAt;
      uint256 updatedAt;
  }
  mapping(uint80 => RoundData) roundDataHistory;
  error RoundIdMissing();
  RoundData _latestRoundData;

  function decimals() external view returns (uint8) {
    return uint8(8);
  }

  function getRoundData(uint80 _roundId)
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) {
    RoundData memory roundData = roundDataHistory[_roundId];
    if(roundData.roundId != _roundId)
      revert RoundIdMissing();
    roundId = _roundId;
    answer = roundData.answer;
    startedAt = roundData.startedAt;
    updatedAt = roundData.updatedAt;
    answeredInRound = roundData.answeredInRound;
  }

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) {
    roundId = _latestRoundData.roundId;
    answer = _latestRoundData.answer;
    startedAt = _latestRoundData.startedAt;
    updatedAt = _latestRoundData.updatedAt;
    answeredInRound = _latestRoundData.answeredInRound;
  }

  function setLatestRoundData(RoundData memory _roundData) external {
    _latestRoundData = _roundData;
//    roundId = uint80(18446744073709551734);
//    answer = int256(318457408617600350);
//    startedAt = uint256(1679508968);
//    updatedAt = uint256(1679508968);
//    answeredInRound = uint80(18446744073709551734);
  }
}
