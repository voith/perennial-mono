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
  RoundData _latestRoundData = RoundData({
    roundId: uint80(18446744073709551734),
    answer: int256(122149510910889330000),
    startedAt: uint256(1679508968),
    updatedAt: uint256(1679508968),
    answeredInRound: uint80(18446744073709551734)
  });

  constructor() {
    roundDataHistory[_latestRoundData.roundId] = _latestRoundData;
  }

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

  function next() external {
    _latestRoundData.roundId = _latestRoundData.roundId + 1;
    _latestRoundData.answer = (_latestRoundData.answer * 101) / 100;
    _latestRoundData.startedAt = _latestRoundData.startedAt + 1;
    _latestRoundData.updatedAt = _latestRoundData.updatedAt + 1;
    _latestRoundData.answeredInRound = _latestRoundData.answeredInRound + 1;
    roundDataHistory[_latestRoundData.roundId] = _latestRoundData;
  }
}
