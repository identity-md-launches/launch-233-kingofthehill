// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title King of the Hill, paid in CRWN
/// @notice A round-based king-of-the-hill game. Anyone can claim the throne by paying at least 110% of what
///         the current king paid. The dethroned king is credited their payment plus a 5% bonus taken from
///         the new claim; the rest of the claim goes to the pot. If nobody outbids the king for 24 hours,
///         anyone can settle the round and the king is credited the pot.
///
///         All payments are pulled with `approve` + `safeTransferFrom`. All payouts are pull-based: the
///         contract only ever credits an internal balance, and the recipient calls `withdraw()` to collect.
///         The contract has no owner, no admin, no pause and no upgrade path, and it never holds ETH.
///
///         Economics (see README): within a round the pot equals the current king's payment minus every
///         bonus paid in that round. A dethroned king always gets back more than they paid. The last king
///         of a round wins the pot, which is less than their own payment once at least one bonus has been
///         paid in that round. That loss is the stake of the game.
/// @dev Invariant: `token.balanceOf(this) == sum(withdrawable) + pot` at all times, so payouts can never
///      exceed payments. `kingPayment` is a record, not escrow: the king's payment has already been split
///      between the previous king and the pot at the moment it was made.
contract KingOfTheHill is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------------------------------------
    // Constants (fixed in code, not configurable)
    // ------------------------------------------------------------------------------------------------

    /// @notice Minimum payment for the first claim of a round: 1,000 CRWN.
    uint256 public constant MIN_FIRST_CLAIM = 1_000 ether;
    /// @notice A later claim must be at least this percentage of the current king's payment (rounded up).
    uint256 public constant RAISE_PERCENT = 110;
    /// @notice Share of every later claim credited to the dethroned king as a bonus (rounded down).
    uint256 public constant BONUS_PERCENT = 5;
    /// @notice A round ends once no claim has been made for this long.
    uint256 public constant ROUND_DURATION = 24 hours;

    // ------------------------------------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------------------------------------

    IERC20 private immutable _token;

    /// @notice Current round number, starting at 1.
    uint256 public round = 1;
    /// @notice Current king, or the zero address when the round has no king yet.
    address public king;
    /// @notice What the current king paid for the throne. A record only; it is not escrowed.
    uint256 public kingPayment;
    /// @notice CRWN accumulated in the current round, paid to the king at settlement.
    uint256 public pot;
    /// @notice Timestamp of the last accepted claim in the current round.
    uint256 public lastClaimAt;

    mapping(address account => uint256 amount) private _withdrawable;

    // ------------------------------------------------------------------------------------------------
    // Events and errors
    // ------------------------------------------------------------------------------------------------

    /// @notice A claim was accepted. `dethroned` is the zero address and `bonus` is zero for a round's first claim.
    event Claimed(
        uint256 indexed round, address indexed king, uint256 amount, address indexed dethroned, uint256 bonus
    );
    /// @notice A round was settled and `prize` (the pot) was credited to `king`.
    event Settled(uint256 indexed round, address indexed king, uint256 prize);
    /// @notice `account` withdrew `amount` CRWN of credited balance.
    event Withdrawn(address indexed account, uint256 amount);

    error ZeroToken();
    error BelowMinimum(uint256 amount, uint256 minimum);
    error AlreadyKing();
    error RoundOver(uint256 deadline);
    error RoundActive(uint256 deadline);
    error NoKing();
    error NothingToWithdraw();

    // ------------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------------

    /// @param token_ The CRWN token address. The contract holds no CRWN at deployment.
    constructor(address token_) {
        if (token_ == address(0)) revert ZeroToken();
        _token = IERC20(token_);
    }

    // ------------------------------------------------------------------------------------------------
    // Actions
    // ------------------------------------------------------------------------------------------------

    /// @notice Claim the throne by paying `amount` CRWN. Requires a prior `approve` on the CRWN token.
    /// @dev First claim of a round: `amount >= 1,000 CRWN`, whole amount goes to the pot, no bonus.
    ///      Later claims: `amount >= ceil(kingPayment * 110 / 100)`, caller must not be the current king,
    ///      and `block.timestamp < lastClaimAt + 24 hours`. The dethroned king is credited
    ///      `kingPayment + floor(amount * 5 / 100)`, and `amount - kingPayment - bonus` goes to the pot.
    function claim(uint256 amount) external nonReentrant {
        address previousKing = king;
        uint256 minimum = minNextClaim();
        if (amount < minimum) revert BelowMinimum(amount, minimum);

        uint256 bonus;
        if (previousKing == address(0)) {
            // First claim of the round: everything goes into the pot.
            pot += amount;
        } else {
            if (msg.sender == previousKing) revert AlreadyKing();
            uint256 roundDeadline = lastClaimAt + ROUND_DURATION;
            if (block.timestamp >= roundDeadline) revert RoundOver(roundDeadline);

            uint256 previousPayment = kingPayment;
            bonus = amount * BONUS_PERCENT / 100;
            // amount >= ceil(previousPayment * 1.1) and bonus <= amount * 0.05, so this never underflows.
            _withdrawable[previousKing] += previousPayment + bonus;
            pot += amount - previousPayment - bonus;
        }

        king = msg.sender;
        kingPayment = amount;
        lastClaimAt = block.timestamp;

        emit Claimed(round, msg.sender, amount, previousKing, bonus);

        _token.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice End the current round once the king has held the throne for 24 hours. Anyone may call.
    /// @dev Credits the king the pot (not the pot plus their payment), clears the throne and starts the
    ///      next round. The exact boundary `block.timestamp == lastClaimAt + 24 hours` belongs to settle.
    function settle() external nonReentrant {
        address currentKing = king;
        if (currentKing == address(0)) revert NoKing();
        uint256 roundDeadline = lastClaimAt + ROUND_DURATION;
        if (block.timestamp < roundDeadline) revert RoundActive(roundDeadline);

        uint256 prize = pot;
        uint256 settledRound = round;

        _withdrawable[currentKing] += prize;
        king = address(0);
        kingPayment = 0;
        pot = 0;
        round = settledRound + 1;

        emit Settled(settledRound, currentKing, prize);
    }

    /// @notice Collect every CRWN credited to the caller. Reverts when nothing is credited.
    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        _withdrawable[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);

        _token.safeTransfer(msg.sender, amount);
    }

    // ------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------

    /// @notice The CRWN token this game is played in.
    function token() external view returns (address) {
        return address(_token);
    }

    /// @notice Minimum payment the next claim must make: 1,000 CRWN when the round has no king,
    ///         otherwise `ceil(kingPayment * 110 / 100)`.
    function minNextClaim() public view returns (uint256) {
        if (king == address(0)) return MIN_FIRST_CLAIM;
        return (kingPayment * RAISE_PERCENT + 99) / 100;
    }

    /// @notice Timestamp from which the round can be settled, or 0 when the round has no king.
    function deadline() external view returns (uint256) {
        if (king == address(0)) return 0;
        return lastClaimAt + ROUND_DURATION;
    }

    /// @notice CRWN credited to `account` and collectable through `withdraw()`.
    function withdrawable(address account) external view returns (uint256) {
        return _withdrawable[account];
    }
}
