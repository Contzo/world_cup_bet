// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IReputationSystem {
    function updateReputation(address user, bool correct) external;
    function getReputation(address user) external view returns (uint256);
    function getWeight(address user) external view returns (uint256);
    function getUserStats(address user)
        external
        view
        returns (uint256 reputation, uint256 totalBets, uint256 correctBets, uint256 accuracy, uint256 weight);
}
