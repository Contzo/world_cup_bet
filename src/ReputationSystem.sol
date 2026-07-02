// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ReputationSystem is Ownable {
    /*//////////////////////////////////////////////////////////////
                           Storage Variables
    //////////////////////////////////////////////////////////////*/
    address public sPredictionMarket;
    mapping(address => uint256) public sReputation;
    mapping(address => uint256) public sTotalBets;
    mapping(address => uint256) public sCorrectBets;

    uint256 public constant BASE_REPUTATION = 100;
    uint256 public constant CORRECT_BET_BONUS = 10;
    uint256 public constant INCORRECT_BET_PENALTY = 5;
    uint256 public constant MAX_REPUTATION = 1000;

    /*//////////////////////////////////////////////////////////////
                                 Events
    //////////////////////////////////////////////////////////////*/
    event ReputationUpdated(address indexed user, uint256 newReputation, bool correct);

    /*//////////////////////////////////////////////////////////////
                                 Errors
    //////////////////////////////////////////////////////////////*/
    error ReputationSystem__NotPredictionMarket();

    /*//////////////////////////////////////////////////////////////
                           Modifiers
    //////////////////////////////////////////////////////////////*/
    modifier onlyPredictionMarket() {
        _onlyPredictionMarket();
        _;
    }

    constructor(address _predictionMarket) Ownable(msg.sender) {
        sPredictionMarket = _predictionMarket;
    }

    /*//////////////////////////////////////////////////////////////
                           External functions
    //////////////////////////////////////////////////////////////*/
    /// @notice Update the reputation of a user based on a prediction
    /// @dev Only the prediction market contract can call this function
    function updateReputation(address user, bool correct) external onlyPredictionMarket {
        if (sReputation[user] == 0) {
            sReputation[user] = BASE_REPUTATION;
        }

        uint256 currentUserReputation = sReputation[user];
        sTotalBets[user] += 1;
        if (correct) {
            sCorrectBets[user] += 1;
            if (currentUserReputation + CORRECT_BET_BONUS > MAX_REPUTATION) {
                sReputation[user] = MAX_REPUTATION;
            } else {
                sReputation[user] += CORRECT_BET_BONUS;
            }
        } else {
            if (currentUserReputation > INCORRECT_BET_PENALTY) {
                sReputation[user] -= INCORRECT_BET_PENALTY;
            }
        }
    }

    /// @notice Get the reputation of a user
    /// @dev If the user has not bet yet, the reputation is set to the base reputation
    /// @return The reputation of the user
    function getReputation(address user) external view returns (uint256) {
        return _getReputation(user);
    }

    /// @notice Get the wieght of a user in the prediction market
    /// @dev The weight is the current reputation scaled by the alltime accuracy of the user
    /// @dev The weight is offsetted by 50 to avoid having a weight of 0 (50% basically means a coin flip)
    /// @return The weight of the user
    function getWeight(address user) external view returns (uint256) {
        return _getWeight(user);
    }

    /// @notice Get the complete stats of a user
    /// @return reputation The reputation of the user
    /// @return totalBets The total number of bets made by the user
    /// @return correctBets The number of correct bets made by the user
    /// @return accuracy The accuracy of the user
    /// @return weight The weight of the user
    function getUserStats(address user)
        external
        view
        returns (uint256 reputation, uint256 totalBets, uint256 correctBets, uint256 accuracy, uint256 weight)
    {
        reputation = _getReputation(user);
        totalBets = sTotalBets[user];
        correctBets = sCorrectBets[user];
        accuracy = _getAccuracy(user);
        weight = _getWeight(user);
    }

    /// @notice Update the market address
    /// @dev Only the owner can call this function
    function setPredictionMarket(address _predictionMarket) external onlyOwner {
        sPredictionMarket = _predictionMarket;
    }

    /*//////////////////////////////////////////////////////////////
                           Internal functions
    //////////////////////////////////////////////////////////////*/
    function _getReputation(address user) internal view returns (uint256) {
        return sReputation[user] == 0 ? BASE_REPUTATION : sReputation[user];
    }

    function _getAccuracy(address user) internal view returns (uint256) {
        return sTotalBets[user] == 0 ? 0 : sCorrectBets[user] * 100 / sTotalBets[user];
    }

    function _getWeight(address user) internal view returns (uint256) {
        if (sTotalBets[user] == 0) return BASE_REPUTATION;

        uint256 userReputaion = _getReputation(user);
        uint256 userAccuracy = _getAccuracy(user);

        return userReputaion * (userAccuracy + 50) / 100;
    }

    function _onlyPredictionMarket() internal view {
        if (msg.sender != address(sPredictionMarket)) revert ReputationSystem__NotPredictionMarket();
    }
}

