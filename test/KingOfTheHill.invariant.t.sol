// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KingOfTheHill} from "../src/KingOfTheHill.sol";

/// @dev Drives the game with a fixed set of players. Every action is bounded so the run is meaningful
///      rather than a stream of reverts, but reverts are still allowed (fail_on_revert = false).
contract KingOfTheHillHandler is Test {
    LaunchToken public token;
    KingOfTheHill public game;
    address[] public players;

    uint256 public totalPaidIn;
    uint256 public totalPaidOut;
    uint256 public bonusesThisRound;
    uint256 public trackedRound;

    constructor(LaunchToken token_, KingOfTheHill game_, address[] memory players_) {
        token = token_;
        game = game_;
        players = players_;
        trackedRound = game.round();
    }

    function _player(uint256 seed) internal view returns (address) {
        return players[seed % players.length];
    }

    function claim(uint256 who, uint256 amountSeed, uint256 hop) external {
        address player = _player(who);
        uint256 minimum = game.minNextClaim();
        uint256 balance = token.balanceOf(player);
        if (balance < minimum) return;
        uint256 amount = bound(amountSeed, minimum, minimum * 3 < balance ? minimum * 3 : balance);
        vm.warp(block.timestamp + bound(hop, 0, 30 hours));

        bool firstClaim = game.king() == address(0);
        vm.prank(player);
        try game.claim(amount) {
            totalPaidIn += amount;
            if (!firstClaim) bonusesThisRound += amount * 5 / 100;
        } catch {}
    }

    function settle(uint256 hop) external {
        vm.warp(block.timestamp + bound(hop, 0, 30 hours));
        try game.settle() {
            bonusesThisRound = 0;
            trackedRound = game.round();
        } catch {}
    }

    function withdraw(uint256 who) external {
        address player = _player(who);
        uint256 credit = game.withdrawable(player);
        vm.prank(player);
        try game.withdraw() {
            totalPaidOut += credit;
        } catch {}
    }

    function sumWithdrawable() external view returns (uint256 total) {
        for (uint256 i; i < players.length; ++i) {
            total += game.withdrawable(players[i]);
        }
    }

    function playerCount() external view returns (uint256) {
        return players.length;
    }
}

contract KingOfTheHillInvariantTest is Test {
    LaunchToken internal token;
    KingOfTheHill internal game;
    KingOfTheHillHandler internal handler;

    function setUp() public {
        vm.warp(1_726_000_123);
        token = new LaunchToken();
        game = new KingOfTheHill(address(token));

        address[] memory players = new address[](5);
        for (uint256 i; i < players.length; ++i) {
            players[i] = makeAddr(string.concat("player", vm.toString(i)));
            assertTrue(token.transfer(players[i], 20_000_000 ether));
            vm.prank(players[i]);
            token.approve(address(game), type(uint256).max);
        }

        handler = new KingOfTheHillHandler(token, game, players);
        targetContract(address(handler));
    }

    /// @notice CRWN held == sum of withdrawable balances + pot, at all times.
    function invariant_heldEqualsCreditsPlusPot() public view {
        assertEq(token.balanceOf(address(game)), handler.sumWithdrawable() + game.pot());
    }

    /// @notice While a round has a king, pot == kingPayment - bonuses paid in that round.
    function invariant_potEqualsKingPaymentMinusBonuses() public view {
        if (game.king() == address(0)) {
            assertEq(game.pot(), 0);
            assertEq(game.kingPayment(), 0);
        } else {
            assertEq(game.pot(), game.kingPayment() - handler.bonusesThisRound());
            assertEq(game.deadline(), game.lastClaimAt() + 24 hours);
        }
    }

    /// @notice Nothing is ever paid out that was not paid in.
    function invariant_payoutsNeverExceedPayments() public view {
        assertLe(handler.totalPaidOut(), handler.totalPaidIn());
        assertEq(handler.totalPaidOut() + token.balanceOf(address(game)), handler.totalPaidIn());
    }

    /// @notice The minimum for the next claim is 1,000 CRWN with no king, otherwise ceil(110%).
    function invariant_minNextClaim() public view {
        if (game.king() == address(0)) {
            assertEq(game.minNextClaim(), 1_000 ether);
        } else {
            assertEq(game.minNextClaim(), (game.kingPayment() * 110 + 99) / 100);
        }
    }

    /// @notice The game never holds ETH and the round counter only moves forward.
    function invariant_roundsAndEth() public view {
        assertEq(address(game).balance, 0);
        assertGe(game.round(), handler.trackedRound());
    }
}
