// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IReputationSystem} from "./interfaces/IReputationSystem.sol";

contract WorldCupPrediction is Ownable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 Types
    //////////////////////////////////////////////////////////////*/
    struct Market {
        uint256 id;
        string question;
        string description;
        string[] outcomes;
        uint256 resolutionTime;
        address arbitrator;
        address creator;
        uint256 createdAt;
        MarketStatus status;
        uint256 totalVolume;
        address tokenAddress;
    }

    struct Bet {
        uint256 id;
        address bettor;
        uint256 marketId;
        uint256 outcomeIndex;
        uint256 amount;
        uint256 shares;
        uint256 timestamp;
        bool claimed;
    }

    enum MarketStatus {
        Open,
        Closed,
        Resolved,
        Cancelled
    }

    /*//////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/
    uint256 public sMarketCount;
    uint256 public sBetCount;
    uint256 public constant PLATFORM_FEE = 2;
    uint256 public constant FEE_DENOMINATOR = 100;

    IReputationSystem public sReputationSystem;

    mapping(uint256 marketId => Market) public sMarkets;
    // Mapping that store the ammount of every outcome pool for every market
    mapping(uint256 marketId => mapping(uint256 poolIndex => uint256 poolAmount)) public sPoolsAmount;
    // Mapping that store the bought share of every outcome pool for every market
    mapping(uint256 marketId => mapping(uint256 poolIndex => uint256 poolShares)) public sPoolsShares;
    // Mapps all the bets to their id
    mapping(uint256 betId => Bet) public sBets;
    // Maps all the bets placed to a market
    mapping(uint256 marketId => uint256[] betsIds) public sMarketBets;
    // Maps all the bets placed by a user
    mapping(address user => uint256[] betIds) public sUsersBets;

    /*//////////////////////////////////////////////////////////////
                                 Errors
    //////////////////////////////////////////////////////////////*/
    error WorldCupPrediction__InvalidOutcomes();
    error WorldCupPrediction__MarketNotOpen();
    error WorldCupPrediction__MarketClosed();
    error WorldCupPrediction__InvalidOutcomeIndex();
    error WorldCupPrediction__ZeroAmount();
    error WorldCupPrediction__SharesTooLow(uint256);
    error WorldCupPrediction__InvalidAmount();
    error WorldCupPrediction__CallerNotArbitrator();
    error WorldCupPrediction__CloseTimeNotReached();

    /*//////////////////////////////////////////////////////////////
                                 Events
    //////////////////////////////////////////////////////////////*/
    event MarketCreated(uint256 indexed marketId, address indexed creator, string question);
    event BetPlaced(uint256 indexed betId, uint256 indexed marketId, address indexed bettor, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint256 indexed winningOutcome);

    constructor(address _reputationSystem) Ownable(msg.sender) {
        sReputationSystem = IReputationSystem(_reputationSystem);
    }

    /*//////////////////////////////////////////////////////////////
                           External Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new market for users to bet on
    /// @param _question The question of the market
    /// @param _description The description of the market
    /// @param _outcomes The possible outcomes of the market
    /// @param _resolutionTime The time when the market will be resolved
    /// @param _arbitrator The address of the arbitrator
    /// @param _tokenAddress The address of the token used for the market
    /// @return The id of the market
    function createMarket(
        string memory _question,
        string memory _description,
        string[] memory _outcomes,
        uint256 _resolutionTime,
        address _arbitrator,
        address _tokenAddress
    ) external returns (uint256) {
        // ── Checks ───────────────────────────────
        // The outcomes must have at least 2 elements
        if (_outcomes.length < 2) revert WorldCupPrediction__InvalidOutcomes();
        // The resolution time must be in the future
        if (block.timestamp >= _resolutionTime) revert WorldCupPrediction__InvalidOutcomes();

        // ── Effects ───────────────────────────────
        sMarketCount++;
        Market storage newMarket = sMarkets[sMarketCount];
        newMarket.id = sMarketCount;
        newMarket.question = _question;
        newMarket.description = _description;
        newMarket.outcomes = _outcomes;
        newMarket.resolutionTime = _resolutionTime;
        newMarket.arbitrator = _arbitrator;
        newMarket.creator = msg.sender;
        newMarket.createdAt = block.timestamp;
        newMarket.status = MarketStatus.Open;
        newMarket.tokenAddress = _tokenAddress;

        emit MarketCreated(sMarketCount, msg.sender, _question);
        return sMarketCount;
    }

    /// @notice Function used to place a bet on a market
    /// @param _marketId The id of the market
    /// @param _outcomeIndex The index of the outcome
    /// @param _amount The amount of the bet
    /// @param _minShares The minimum amount of shares to buy
    function placeBet(uint256 _marketId, uint256 _outcomeIndex, uint256 _amount, uint256 _minShares)
        external
        payable
        returns (uint256)
    {
        // ── Checks ───────────────────────────────
        Market storage market = sMarkets[_marketId];
        // The market must be open
        if (market.status != MarketStatus.Open) revert WorldCupPrediction__MarketNotOpen();
        // Check if the time limit for the market has been reached
        if (block.timestamp >= market.resolutionTime) revert WorldCupPrediction__MarketClosed();
        // Check if the outcome index is valid
        if (_outcomeIndex >= market.outcomes.length) revert WorldCupPrediction__InvalidOutcomeIndex();
        // Check if the amount is greater than 0
        if (_amount == 0) revert WorldCupPrediction__ZeroAmount();
        // If the bet is paid in ETH, check if the amount is equal to the msg.value
        if (market.tokenAddress == address(0) && msg.value != _amount) revert WorldCupPrediction__InvalidAmount();

        // Compute shares
        uint256 shares = _calculateShares(_marketId, _outcomeIndex, _amount);
        // Check if the shares are greater than the minimum shares
        if (shares < _minShares) revert WorldCupPrediction__SharesTooLow(shares);

        // ── Effects ───────────────────────────────
        sBetCount++;
        Bet storage bet = sBets[sBetCount];
        bet.id = sBetCount;
        bet.bettor = msg.sender;
        bet.marketId = _marketId;
        bet.outcomeIndex = _outcomeIndex;
        bet.amount = _amount;
        bet.shares = shares;
        bet.timestamp = block.timestamp;
        bet.claimed = false;

        sPoolsAmount[_marketId][_outcomeIndex] += _amount;
        sPoolsShares[_marketId][_outcomeIndex] += shares;
        sMarketBets[_marketId].push(sBetCount);
        sUsersBets[msg.sender].push(sBetCount);

        emit BetPlaced(sBetCount, _marketId, msg.sender, _amount);

        // ── Interact ─────────────────────────────
        if (market.tokenAddress != address(0)) {
            // Transfer ERC20 to the market address
            IERC20(market.tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }
        // For ETH, the amount is already in the contract via msg.value

        return sBetCount;
    }

    /*//////////////////////////////////////////////////////////////
                            Public Functions
    //////////////////////////////////////////////////////////////*/
    /// @notice Get the shares for a bet
    /// @param _marketId The id of the market
    /// @param _outcomeIndex The index of the outcome
    /// @param _amount The amount to bet
    /// @return shares The number of shares to receive
    function getShares(uint256 _marketId, uint256 _outcomeIndex, uint256 _amount) external view returns (uint256) {
        return _calculateShares(_marketId, _outcomeIndex, _amount);
    }

    /// @notice Get the total pool size for a market
    /// @param _marketId The id of the market
    /// @return The total pool size
    function getTotalPool(uint256 _marketId) external view returns (uint256) {
        return _getTotalPool(_marketId);
    }

    /// @notice resolve the market
    /// @param _marketId The id of the market
    /// @param _winningOutcome The index of the winning outcome
    /// @inheritdoc Copies all missing tags from the base function (must be followed by the contract name)
    function resolveMarket(uint256 _marketId, uint256 _winningOutcome) external {
        // ── Checks ───────────────────────────────
        Market memory market = sMarkets[_marketId];
        if (msg.sender != market.arbitrator) revert WorldCupPrediction__CallerNotArbitrator();
        if (market.status != MarketStatus.Open) revert WorldCupPrediction__MarketNotOpen();
        if (block.timestamp < market.resolutionTime) revert WorldCupPrediction__CloseTimeNotReached();
        if (_winningOutcome >= market.outcomes.length) revert WorldCupPrediction__InvalidOutcomeIndex();

        // ── Effects ───────────────────────────────
        market.status = MarketStatus.Resolved;
        market.winningOutcome = _winningOutcome;

        emit MarketResolved(_marketId, _winningOutcome);
    }

    /*//////////////////////////////////////////////////////////////
                        Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate shares for a bet based on the current pool state
    /// @param _marketId The id of the market
    /// @param _outcomeIndex The index of the outcome
    /// @param _amount The amount to bet
    /// @return The number of shares to receive
    function _calculateShares(uint256 _marketId, uint256 _outcomeIndex, uint256 _amount) public view returns (uint256) {
        uint256 currentPool = sPoolsAmount[_marketId][_outcomeIndex];
        if (currentPool == 0) return _amount * 100;

        uint256 totalPool = _getTotalPool(_marketId);
        uint256 newPool = currentPool + _amount;

        return (_amount * 100 * totalPool) / (newPool * currentPool);
    }

    /// @notice Get the total pool size for a market
    /// @param _marketId The id of the market
    /// @return The total pool size
    function _getTotalPool(uint256 _marketId) public view returns (uint256) {
        Market storage market = sMarkets[_marketId];
        uint256 total = 0;
        for (uint256 i = 0; i < market.outcomes.length; i++) {
            total += sPoolsAmount[_marketId][i];
        }
        return total;
    }
}
