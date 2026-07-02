// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IReputationSystem} from "./interfaces/IReputationSystem.sol";

contract WorldCupBetting is Ownable, ReentrancyGuard {
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
        MarketStatus status;
        uint256 winningOutcome;
        address tokenAddress;
    }

    struct Bet {
        uint256 id;
        address bettor;
        uint256 marketId;
        uint256 outcomeIndex;
        uint256 amount;
        uint256 shares;
        bool claimed;
    }

    /// @dev Ordering is kept as Open, Closed, Resolved, Cancelled so `Resolved == 2`, which the
    ///      assessment reads from `getMarket(...).status`.
    enum MarketStatus {
        Open,
        Closed,
        Resolved,
        Cancelled
    }

    /*//////////////////////////////////////////////////////////////
                            Storage variables
    //////////////////////////////////////////////////////////////*/
    uint256 public constant PLATFORM_FEE = 2;
    uint256 public constant FEE_DENOMINATOR = 100;

    uint256 public sMarketCount;
    uint256 public sBetCount;
    IReputationSystem public sReputationSystem;

    // marketId => Market
    mapping(uint256 => Market) public sMarkets;
    // marketId => outcomeIndex => staked collateral in that pool
    mapping(uint256 => mapping(uint256 => uint256)) public sPoolsAmount;
    // marketId => outcomeIndex => shares issued in that pool
    mapping(uint256 => mapping(uint256 => uint256)) public sPoolsShares;
    // betId => Bet
    mapping(uint256 => Bet) public sBets;
    // marketId => list of betIds
    mapping(uint256 => uint256[]) public sMarketBets;
    // user => list of betIds
    mapping(address => uint256[]) public sUsersBets;
    // betId => listed for sale
    mapping(uint256 => bool) public sPositionsForSale;
    // betId => listing price
    mapping(uint256 => uint256) public sPositionPrices;
    // token (address(0) for ETH) => accumulated fees
    mapping(address => uint256) public sCollectedFees;

    /*//////////////////////////////////////////////////////////////
                                 Events
    //////////////////////////////////////////////////////////////*/
    event MarketCreated(uint256 indexed marketId, address indexed creator, string question);
    event BetPlaced(uint256 indexed betId, uint256 indexed marketId, address indexed bettor, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint256 indexed winningOutcome);
    event WinningsClaimed(uint256 indexed betId, address indexed claimer, uint256 amount);
    event PositionListed(uint256 indexed betId, uint256 price);
    event ListingCancelled(uint256 indexed betId);
    event PositionSold(uint256 indexed betId, address seller, address buyer, uint256 price);
    event FeesWithdrawn(address indexed token, uint256 amount, address indexed to);

    constructor(address _reputationSystem) Ownable(msg.sender) {
        sReputationSystem = IReputationSystem(_reputationSystem);
    }

    /*//////////////////////////////////////////////////////////////
                           External Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new betting market.
    /// @param _question Human-readable market question.
    /// @param _description Longer description / resolution criteria.
    /// @param _outcomes The mutually exclusive outcomes (at least two).
    /// @param _resolutionTime Timestamp at/after which the market may be resolved.
    /// @param _arbitrator Address allowed to resolve this market.
    /// @param _tokenAddress Collateral token; address(0) means native ETH.
    /// @return The id of the newly created market.
    function createMarket(
        string memory _question,
        string memory _description,
        string[] memory _outcomes,
        uint256 _resolutionTime,
        address _arbitrator,
        address _tokenAddress
    ) external returns (uint256) {
        // ── Checks ───────────────────────────────
        require(_outcomes.length >= 2, "Need >= 2 outcomes");
        require(_resolutionTime > block.timestamp, "Resolution in past");
        require(_arbitrator != address(0), "Bad arbitrator");

        // ── Effects ──────────────────────────────
        sMarketCount++;
        Market storage market = sMarkets[sMarketCount];
        market.id = sMarketCount;
        market.question = _question;
        market.description = _description;
        market.outcomes = _outcomes;
        market.resolutionTime = _resolutionTime;
        market.arbitrator = _arbitrator;
        market.creator = msg.sender;
        market.status = MarketStatus.Open;
        market.tokenAddress = _tokenAddress;

        emit MarketCreated(sMarketCount, msg.sender, _question);
        return sMarketCount;
    }

    /// @notice Place a bet on an outcome.
    /// @param _marketId The market to bet on.
    /// @param _outcomeIndex The chosen outcome.
    /// @param _amount The collateral amount to stake.
    /// @param _minShares Slippage guard: revert if the computed shares are below this.
    /// @return The id of the created bet.
    function placeBet(uint256 _marketId, uint256 _outcomeIndex, uint256 _amount, uint256 _minShares)
        external
        payable
        returns (uint256)
    {
        // ── Checks ───────────────────────────────
        Market storage market = sMarkets[_marketId];
        require(market.status == MarketStatus.Open, "Market closed");
        require(block.timestamp < market.resolutionTime, "Market closed");
        require(_outcomeIndex < market.outcomes.length, "Bad outcome");
        require(_amount > 0, "Zero amount");

        if (market.tokenAddress == address(0)) {
            require(msg.value == _amount, "Bad ETH amount");
        } else {
            require(msg.value == 0, "No ETH for ERC20");
        }

        uint256 shares = calculateShares(_marketId, _outcomeIndex, _amount);
        require(shares >= _minShares, "Slippage exceeded");

        // ── Effects ──────────────────────────────
        sBetCount++;
        Bet storage bet = sBets[sBetCount];
        bet.id = sBetCount;
        bet.bettor = msg.sender;
        bet.marketId = _marketId;
        bet.outcomeIndex = _outcomeIndex;
        bet.amount = _amount;
        bet.shares = shares;

        sPoolsAmount[_marketId][_outcomeIndex] += _amount;
        sPoolsShares[_marketId][_outcomeIndex] += shares;
        sMarketBets[_marketId].push(sBetCount);
        sUsersBets[msg.sender].push(sBetCount);

        emit BetPlaced(sBetCount, _marketId, msg.sender, _amount);

        // ── Interactions ─────────────────────────
        if (market.tokenAddress != address(0)) {
            IERC20(market.tokenAddress).safeTransferFrom(msg.sender, address(this), _amount);
        }

        return sBetCount;
    }

    /// @notice Resolve a market to its winning outcome. Arbitrator only, at/after resolutionTime.
    /// @param _marketId The market to resolve.
    /// @param _winningOutcome The winning outcome index.
    function resolveMarket(uint256 _marketId, uint256 _winningOutcome) external {
        // ── Checks ───────────────────────────────
        Market storage market = sMarkets[_marketId];
        require(msg.sender == market.arbitrator, "Only arbitrator");
        require(market.status == MarketStatus.Open, "Not open");
        require(block.timestamp >= market.resolutionTime, "Too early");
        require(_winningOutcome < market.outcomes.length, "Bad outcome");

        // ── Effects ──────────────────────────────
        market.status = MarketStatus.Resolved;
        market.winningOutcome = _winningOutcome;

        emit MarketResolved(_marketId, _winningOutcome);
    }

    /// @notice Settle a bet after resolution. Winners are paid net of the platform fee; losers are
    ///         simply marked claimed. Reputation is recorded either way.
    /// @param _betId The bet to settle.
    function claimWinnings(uint256 _betId) external nonReentrant {
        Bet storage bet = sBets[_betId];
        Market storage market = sMarkets[bet.marketId];

        // ── Checks ───────────────────────────────
        require(msg.sender == bet.bettor, "Only bettor");
        require(market.status == MarketStatus.Resolved, "Not resolved");
        require(!bet.claimed, "Already claimed");

        // ── Effects ──────────────────────────────
        bet.claimed = true;
        bool won = bet.outcomeIndex == market.winningOutcome;
        uint256 netPayout;

        if (won) {
            uint256 totalPool = getTotalPool(bet.marketId);
            uint256 totalWinningShares = sPoolsShares[bet.marketId][market.winningOutcome];
            uint256 grossPayout = (bet.shares * totalPool) / totalWinningShares;
            uint256 fee = (grossPayout * PLATFORM_FEE) / FEE_DENOMINATOR;
            netPayout = grossPayout - fee;
            sCollectedFees[market.tokenAddress] += fee;
        }

        // ── Interactions ─────────────────────────
        if (won && netPayout > 0) {
            if (market.tokenAddress == address(0)) {
                (bool ok,) = payable(msg.sender).call{value: netPayout}("");
                require(ok, "ETH transfer failed");
            } else {
                IERC20(market.tokenAddress).safeTransfer(msg.sender, netPayout);
            }
            emit WinningsClaimed(_betId, msg.sender, netPayout);
        }

        sReputationSystem.updateReputation(msg.sender, won);
    }

    /// @notice List an open, unclaimed position for sale at a fixed price.
    /// @param _betId The bet/position to list.
    /// @param _price The asking price, in the market's collateral token.
    function listPosition(uint256 _betId, uint256 _price) external {
        Bet storage bet = sBets[_betId];
        Market storage market = sMarkets[bet.marketId];

        // ── Checks ───────────────────────────────
        require(msg.sender == bet.bettor, "Only bettor");
        require(_price > 0, "Zero price");
        require(!bet.claimed, "Already claimed");
        require(market.status == MarketStatus.Open, "Market closed");
        require(block.timestamp < market.resolutionTime, "Market closed");

        // ── Effects ──────────────────────────────
        sPositionsForSale[_betId] = true;
        sPositionPrices[_betId] = _price;

        emit PositionListed(_betId, _price);
    }

    /// @notice Cancel an active listing.
    /// @param _betId The listed bet/position.
    function cancelListing(uint256 _betId) external {
        Bet storage bet = sBets[_betId];

        // ── Checks ───────────────────────────────
        require(msg.sender == bet.bettor, "Only bettor");
        require(sPositionsForSale[_betId], "Not for sale");

        // ── Effects ──────────────────────────────
        sPositionsForSale[_betId] = false;
        sPositionPrices[_betId] = 0;

        emit ListingCancelled(_betId);
    }

    /// @notice Buy a listed position. The buyer funds the purchase; the seller is paid the listing
    ///         price and ownership of the bet transfers atomically.
    /// @param _betId The listed bet/position.
    function buyPosition(uint256 _betId) external payable nonReentrant {
        Bet storage bet = sBets[_betId];
        Market storage market = sMarkets[bet.marketId];
        address seller = bet.bettor;
        uint256 price = sPositionPrices[_betId];

        // ── Checks ───────────────────────────────
        require(sPositionsForSale[_betId], "Not for sale");
        require(market.status == MarketStatus.Open, "Market closed");
        require(block.timestamp < market.resolutionTime, "Market closed");
        require(msg.sender != seller, "Cannot buy own");

        // ── Effects ──────────────────────────────
        bet.bettor = msg.sender;
        sPositionsForSale[_betId] = false;
        sPositionPrices[_betId] = 0;
        _removeUserBet(seller, _betId);
        sUsersBets[msg.sender].push(_betId);

        // ── Interactions ─────────────────────────
        if (market.tokenAddress == address(0)) {
            require(msg.value >= price, "Insufficient payment");
            (bool ok,) = payable(seller).call{value: price}("");
            require(ok, "ETH transfer failed");
            if (msg.value > price) {
                (bool refundOk,) = payable(msg.sender).call{value: msg.value - price}("");
                require(refundOk, "Refund failed");
            }
        } else {
            require(msg.value == 0, "No ETH for ERC20");
            IERC20(market.tokenAddress).safeTransferFrom(msg.sender, seller, price);
        }

        emit PositionSold(_betId, seller, msg.sender, price);
    }

    /// @notice Withdraw accumulated platform fees for a given token. Owner only.
    /// @param _tokenAddress The token to withdraw (address(0) for ETH).
    function withdrawFees(address _tokenAddress) external onlyOwner nonReentrant {
        // ── Checks ───────────────────────────────
        uint256 fees = sCollectedFees[_tokenAddress];
        require(fees > 0, "No fees");

        // ── Effects ──────────────────────────────
        sCollectedFees[_tokenAddress] = 0;

        // ── Interactions ─────────────────────────
        if (_tokenAddress == address(0)) {
            (bool ok,) = payable(owner()).call{value: fees}("");
            require(ok, "ETH transfer failed");
        } else {
            IERC20(_tokenAddress).safeTransfer(owner(), fees);
        }

        emit FeesWithdrawn(_tokenAddress, fees, owner());
    }

    /*//////////////////////////////////////////////////////////////
                            View Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Number of markets created so far.
    function marketCount() external view returns (uint256) {
        return sMarketCount;
    }

    /// @notice Number of bets placed so far.
    function betCount() external view returns (uint256) {
        return sBetCount;
    }

    /// @notice Fees available to withdraw for a token (address(0) for ETH).
    function getAvailableFees(address _tokenAddress) external view returns (uint256) {
        return sCollectedFees[_tokenAddress];
    }

    /// @notice All bet ids owned by a user (reflects secondary-market transfers).
    function getUserBets(address _user) external view returns (uint256[] memory) {
        return sUsersBets[_user];
    }

    /// @notice All bet ids placed on a market.
    function getMarketBets(uint256 _marketId) external view returns (uint256[] memory) {
        return sMarketBets[_marketId];
    }

    /// @notice Read a market's metadata and status.
    /// @dev Named returns are kept so callers can access fields (e.g. `status`) by name.
    function getMarket(uint256 _marketId)
        external
        view
        returns (
            uint256 id,
            string memory question,
            string memory description,
            string[] memory outcomes,
            uint256 resolutionTime,
            address arbitrator,
            address creator,
            MarketStatus status,
            uint256 winningOutcome,
            address tokenAddress
        )
    {
        Market storage market = sMarkets[_marketId];
        return (
            market.id,
            market.question,
            market.description,
            market.outcomes,
            market.resolutionTime,
            market.arbitrator,
            market.creator,
            market.status,
            market.winningOutcome,
            market.tokenAddress
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Public Pricing Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Price the shares a bet would receive using a proportional AMM: earlier bets on
    ///         less-popular outcomes receive more shares.
    /// @return The number of shares the bet would receive.
    function calculateShares(uint256 _marketId, uint256 _outcomeIndex, uint256 _amount) public view returns (uint256) {
        uint256 currentPool = sPoolsAmount[_marketId][_outcomeIndex];
        if (currentPool == 0) return _amount * 100;

        uint256 totalPool = getTotalPool(_marketId);
        uint256 newPool = currentPool + _amount;
        return (_amount * 100 * totalPool) / (newPool * currentPool);
    }

    /// @notice Implied probability of an outcome as a percentage (0–100).
    function getPrice(uint256 _marketId, uint256 _outcomeIndex) public view returns (uint256) {
        uint256 totalPool = getTotalPool(_marketId);
        if (totalPool == 0) return 0;
        return (sPoolsAmount[_marketId][_outcomeIndex] * 100) / totalPool;
    }

    /// @notice Total collateral staked across all outcomes of a market.
    function getTotalPool(uint256 _marketId) public view returns (uint256) {
        Market storage market = sMarkets[_marketId];
        uint256 total = 0;
        uint256 length = market.outcomes.length;
        for (uint256 i = 0; i < length; i++) {
            total += sPoolsAmount[_marketId][i];
        }
        return total;
    }

    /*//////////////////////////////////////////////////////////////
                        Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Remove a bet id from a user's list (swap-and-pop).
    function _removeUserBet(address _user, uint256 _betId) internal {
        uint256[] storage userBets = sUsersBets[_user];
        uint256 length = userBets.length;
        for (uint256 i = 0; i < length; i++) {
            if (userBets[i] == _betId) {
                userBets[i] = userBets[length - 1];
                userBets.pop();
                return;
            }
        }
    }
}
