// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {KingOfTheHill} from "../src/KingOfTheHill.sol";

/// @dev A player that is a contract. It can claim, settle and withdraw like an EOA, and it can try to
///      re-enter the game from within a call, which is only reachable through a token with callbacks.
contract ContractPlayer {
    KingOfTheHill internal game;
    IERC20 internal token;

    constructor(KingOfTheHill game_, IERC20 token_) {
        game = game_;
        token = token_;
        token.approve(address(game), type(uint256).max);
    }

    function claim(uint256 amount) external {
        game.claim(amount);
    }

    function settle() external {
        game.settle();
    }

    function withdraw() external {
        game.withdraw();
    }
}

/// @dev An ERC-20 that calls back into the recipient/sender on every transfer, standing in for an
///      ERC-777-style token, so the reentrancy guard can be exercised. CRWN itself has no callbacks.
contract CallbackToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    address public hook;
    bytes public reentrantCall;
    bool public reentrantOk;
    bytes public reentrantError;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function setReentrancy(address hook_, bytes calldata data) external {
        hook = hook_;
        reentrantCall = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (hook != address(0) && reentrantCall.length != 0) {
            bytes memory data = reentrantCall;
            delete reentrantCall;
            (bool ok, bytes memory err) = hook.call(data);
            reentrantOk = ok;
            reentrantError = err;
        }
    }
}

contract KingOfTheHillTest is Test {
    uint256 internal constant START = 1_726_000_123;
    uint256 internal constant DAY = 24 hours;
    uint256 internal constant MIN = 1_000 ether;

    LaunchToken internal token;
    KingOfTheHill internal game;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal outsider = makeAddr("outsider");

    event Claimed(
        uint256 indexed round, address indexed king, uint256 amount, address indexed dethroned, uint256 bonus
    );
    event Settled(uint256 indexed round, address indexed king, uint256 prize);
    event Withdrawn(address indexed account, uint256 amount);

    function setUp() public {
        vm.warp(START);
        vm.prank(deployer);
        token = new LaunchToken();
        game = new KingOfTheHill(address(token));

        _fund(alice, 10_000_000 ether);
        _fund(bob, 10_000_000 ether);
        _fund(carol, 10_000_000 ether);
    }

    function _fund(address who, uint256 amount) internal {
        vm.prank(deployer);
        assertTrue(token.transfer(who, amount));
        vm.prank(who);
        token.approve(address(game), type(uint256).max);
    }

    function _claim(address who, uint256 amount) internal {
        vm.prank(who);
        game.claim(amount);
    }

    function ceil110(uint256 x) internal pure returns (uint256) {
        return (x * 110 + 99) / 100;
    }

    // ----------------------------------------------------------------------------------------------
    // Deployment
    // ----------------------------------------------------------------------------------------------

    function test_constructorBindsTokenAndHoldsNothing() public view {
        assertEq(game.token(), address(token));
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.round(), 1);
        assertEq(game.king(), address(0));
        assertEq(game.kingPayment(), 0);
        assertEq(game.pot(), 0);
        assertEq(game.lastClaimAt(), 0);
        assertEq(game.deadline(), 0);
        assertEq(game.minNextClaim(), MIN);
        assertEq(game.MIN_FIRST_CLAIM(), MIN);
        assertEq(game.RAISE_PERCENT(), 110);
        assertEq(game.BONUS_PERCENT(), 5);
        assertEq(game.ROUND_DURATION(), DAY);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(KingOfTheHill.ZeroToken.selector);
        new KingOfTheHill(address(0));
    }

    function test_rejectsEth() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(game).call{value: 1}("");
        assertFalse(ok, "game accepted ETH");
        vm.prank(alice);
        (ok,) = address(game).call{value: 1}(abi.encodeWithSignature("claim(uint256)", MIN));
        assertFalse(ok, "payable claim");
        assertEq(address(game).balance, 0);
    }

    // ----------------------------------------------------------------------------------------------
    // First claim of a round
    // ----------------------------------------------------------------------------------------------

    function test_firstClaimBelowMinimumReverts() public {
        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.BelowMinimum.selector, MIN - 1, MIN));
        _claim(alice, MIN - 1);
        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.BelowMinimum.selector, 0, MIN));
        _claim(alice, 0);
    }

    function test_firstClaimAtMinimumSucceeds() public {
        vm.expectEmit(true, true, true, true, address(game));
        emit Claimed(1, alice, MIN, address(0), 0);
        _claim(alice, MIN);

        assertEq(game.king(), alice);
        assertEq(game.kingPayment(), MIN);
        assertEq(game.pot(), MIN);
        assertEq(game.lastClaimAt(), START);
        assertEq(game.deadline(), START + DAY);
        assertEq(game.minNextClaim(), 1_100 ether);
        assertEq(game.withdrawable(alice), 0);
        assertEq(token.balanceOf(address(game)), MIN);
        assertEq(token.balanceOf(alice), 10_000_000 ether - MIN);
    }

    function test_firstClaimAboveMinimumGoesWhollyToPot() public {
        _claim(alice, 5_000 ether);
        assertEq(game.pot(), 5_000 ether);
        assertEq(game.kingPayment(), 5_000 ether);
        assertEq(game.minNextClaim(), 5_500 ether);
    }

    function test_claimWithoutAllowanceReverts() public {
        vm.prank(alice);
        token.approve(address(game), 0);
        vm.expectRevert();
        _claim(alice, MIN);
        assertEq(game.king(), address(0));
    }

    function test_claimWithoutBalanceReverts() public {
        vm.prank(outsider);
        token.approve(address(game), type(uint256).max);
        vm.expectRevert();
        _claim(outsider, MIN);
    }

    // ----------------------------------------------------------------------------------------------
    // Later claims: the 110% boundary, the split, self-claims
    // ----------------------------------------------------------------------------------------------

    function test_laterClaimBoundaryExactMultiple() public {
        _claim(alice, MIN);
        uint256 minimum = 1_100 ether;
        assertEq(game.minNextClaim(), minimum);

        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.BelowMinimum.selector, minimum - 1, minimum));
        _claim(bob, minimum - 1);

        _claim(bob, minimum);
        assertEq(game.king(), bob);
    }

    function test_laterClaimBoundaryRoundsUp() public {
        // 110% of (1000e18 + 1) is 1100e18 + 1.1, which must round up to 1100e18 + 2.
        _claim(alice, MIN + 1);
        uint256 minimum = 1_100 ether + 2;
        assertEq(game.minNextClaim(), minimum);
        assertEq(minimum, ceil110(MIN + 1));

        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.BelowMinimum.selector, minimum - 1, minimum));
        _claim(bob, minimum - 1);

        _claim(bob, minimum);
        assertEq(game.king(), bob);
        assertEq(game.kingPayment(), minimum);
    }

    function test_laterClaimSplitsBetweenDethronedKingAndPot() public {
        _claim(alice, MIN);
        uint256 amount = 1_234_567_890_123_456_789_012; // an awkward number above 1,100 CRWN
        uint256 bonus = amount * 5 / 100;

        vm.expectEmit(true, true, true, true, address(game));
        emit Claimed(1, bob, amount, alice, bonus);
        _claim(bob, amount);

        assertEq(game.king(), bob);
        assertEq(game.kingPayment(), amount);
        assertEq(game.withdrawable(alice), MIN + bonus);
        assertEq(game.pot(), amount - bonus);
        assertEq(game.pot(), MIN + (amount - MIN - bonus));
        assertEq(game.lastClaimAt(), START);
        assertEq(token.balanceOf(address(game)), MIN + amount);
        assertEq(token.balanceOf(address(game)), game.withdrawable(alice) + game.pot());
    }

    function test_bonusRoundsDown() public {
        _claim(alice, MIN);
        uint256 amount = 1_100 ether + 19; // 5% is 55e18 + 0.95, floored
        _claim(bob, amount);
        assertEq(game.withdrawable(alice), MIN + 55 ether);
        assertEq(game.pot(), amount - 55 ether);
    }

    function test_selfClaimRefused() public {
        _claim(alice, MIN);
        vm.expectRevert(KingOfTheHill.AlreadyKing.selector);
        _claim(alice, 2_000 ether);
        // A below-minimum self-claim fails on the minimum first.
        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.BelowMinimum.selector, MIN, 1_100 ether));
        _claim(alice, MIN);
        assertEq(game.king(), alice);
        assertEq(game.kingPayment(), MIN);
    }

    function test_reclaimAfterBeingDethronedIsAllowed() public {
        _claim(alice, MIN);
        _claim(bob, 1_100 ether);
        _claim(alice, 1_210 ether);
        assertEq(game.king(), alice);
        assertEq(game.withdrawable(alice), MIN + 55 ether);
        assertEq(game.withdrawable(bob), 1_100 ether + 60.5 ether);
        assertEq(token.balanceOf(address(game)), game.withdrawable(alice) + game.withdrawable(bob) + game.pot());
    }

    // ----------------------------------------------------------------------------------------------
    // The 24-hour boundary: claim versus settle
    // ----------------------------------------------------------------------------------------------

    function test_claimOneSecondBeforeDeadlineSucceedsAndExtends() public {
        _claim(alice, MIN);
        vm.warp(START + DAY - 1);
        _claim(bob, 1_100 ether);
        assertEq(game.lastClaimAt(), START + DAY - 1);
        assertEq(game.deadline(), START + 2 * DAY - 1);
    }

    function test_claimAtDeadlineReverts() public {
        _claim(alice, MIN);
        vm.warp(START + DAY);
        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.RoundOver.selector, START + DAY));
        _claim(bob, 1_100 ether);
    }

    function test_claimAfterDeadlineReverts() public {
        _claim(alice, MIN);
        vm.warp(START + DAY + 7 days);
        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.RoundOver.selector, START + DAY));
        _claim(bob, 1_100 ether);
    }

    function test_settleBeforeDeadlineReverts() public {
        _claim(alice, MIN);
        vm.warp(START + DAY - 1);
        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.RoundActive.selector, START + DAY));
        game.settle();
    }

    function test_settleAtDeadlineSucceeds() public {
        _claim(alice, MIN);
        vm.warp(START + DAY);
        vm.expectEmit(true, true, true, true, address(game));
        emit Settled(1, alice, MIN);
        vm.prank(outsider);
        game.settle();

        assertEq(game.round(), 2);
        assertEq(game.king(), address(0));
        assertEq(game.kingPayment(), 0);
        assertEq(game.pot(), 0);
        assertEq(game.deadline(), 0);
        assertEq(game.minNextClaim(), MIN);
        assertEq(game.withdrawable(alice), MIN);
    }

    function test_settleWithoutKingReverts() public {
        vm.expectRevert(KingOfTheHill.NoKing.selector);
        game.settle();

        // Also after a round has been settled: the new round has no king.
        _claim(alice, MIN);
        vm.warp(START + DAY);
        game.settle();
        vm.expectRevert(KingOfTheHill.NoKing.selector);
        game.settle();
    }

    function test_settleCreditsPotNotPotPlusPayment() public {
        _claim(alice, MIN);
        _claim(bob, 2_000 ether);
        uint256 bonus = 100 ether;
        assertEq(game.pot(), 2_000 ether - bonus);
        vm.warp(START + DAY);
        game.settle();
        assertEq(game.withdrawable(bob), 2_000 ether - bonus);
        assertEq(game.withdrawable(alice), MIN + bonus);
        assertEq(token.balanceOf(address(game)), game.withdrawable(alice) + game.withdrawable(bob));
    }

    function test_nextRoundStartsAtMinimumAgain() public {
        _claim(alice, MIN);
        _claim(bob, 500_000 ether);
        vm.warp(START + DAY);
        game.settle();

        // A claim of 1,000 CRWN is enough again, even though the last king paid 500,000.
        vm.warp(START + DAY + 3);
        _claim(carol, MIN);
        assertEq(game.round(), 2);
        assertEq(game.king(), carol);
        assertEq(game.kingPayment(), MIN);
        assertEq(game.pot(), MIN);
        assertEq(game.lastClaimAt(), START + DAY + 3);
        // Previous credits survive the round change.
        assertEq(game.withdrawable(bob), 500_000 ether - 25_000 ether);
    }

    function test_deadlineIsNotEditedByTimeAlone() public {
        _claim(alice, MIN);
        vm.warp(START + DAY - 1);
        assertEq(game.deadline(), START + DAY);
        vm.warp(START + 30 days);
        assertEq(game.deadline(), START + DAY);
    }

    // ----------------------------------------------------------------------------------------------
    // Withdraw
    // ----------------------------------------------------------------------------------------------

    function test_withdrawPaysCreditAndZeroesIt() public {
        _claim(alice, MIN);
        _claim(bob, 1_100 ether);
        uint256 credit = MIN + 55 ether;
        uint256 before = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(game));
        emit Withdrawn(alice, credit);
        vm.prank(alice);
        game.withdraw();

        assertEq(token.balanceOf(alice), before + credit);
        assertEq(game.withdrawable(alice), 0);
        assertEq(token.balanceOf(address(game)), game.pot());

        vm.expectRevert(KingOfTheHill.NothingToWithdraw.selector);
        vm.prank(alice);
        game.withdraw();
    }

    function test_withdrawWithNothingCreditedReverts() public {
        vm.expectRevert(KingOfTheHill.NothingToWithdraw.selector);
        vm.prank(outsider);
        game.withdraw();

        // Being king does not make the payment withdrawable.
        _claim(alice, MIN);
        vm.expectRevert(KingOfTheHill.NothingToWithdraw.selector);
        vm.prank(alice);
        game.withdraw();
    }

    function test_withdrawByThirdPartyCannotTouchOthersCredit() public {
        _claim(alice, MIN);
        _claim(bob, 1_100 ether);
        vm.expectRevert(KingOfTheHill.NothingToWithdraw.selector);
        vm.prank(outsider);
        game.withdraw();
        assertEq(game.withdrawable(alice), MIN + 55 ether);
    }

    // ----------------------------------------------------------------------------------------------
    // Contract players and reentrancy
    // ----------------------------------------------------------------------------------------------

    function test_contractKingPlaysAndCollects() public {
        ContractPlayer player = new ContractPlayer(game, IERC20(address(token)));
        vm.prank(deployer);
        assertTrue(token.transfer(address(player), 100_000 ether));

        player.claim(MIN);
        assertEq(game.king(), address(player));

        _claim(bob, 1_100 ether);
        assertEq(game.withdrawable(address(player)), MIN + 55 ether);

        player.claim(1_210 ether);
        vm.warp(START + DAY);
        player.settle();
        // Prize is the pot: the last payment minus every bonus paid in the round (55 + 60.5).
        uint256 prize = 1_210 ether - 55 ether - 60.5 ether;
        assertEq(game.withdrawable(address(player)), MIN + 55 ether + prize);

        uint256 before = token.balanceOf(address(player));
        player.withdraw();
        assertEq(token.balanceOf(address(player)), before + MIN + 55 ether + prize);
        assertEq(token.balanceOf(address(game)), game.withdrawable(bob));
    }

    function test_contractKingCannotBlockOthers() public {
        // A king that never withdraws (or cannot) does not stop anyone else from claiming, settling or
        // withdrawing, because nothing is ever pushed to it.
        ContractPlayer player = new ContractPlayer(game, IERC20(address(token)));
        vm.prank(deployer);
        assertTrue(token.transfer(address(player), 100_000 ether));
        player.claim(MIN);
        _claim(bob, 1_100 ether);
        vm.warp(START + DAY);
        vm.prank(outsider);
        game.settle();
        vm.prank(bob);
        game.withdraw();
        assertEq(token.balanceOf(address(game)), game.withdrawable(address(player)));
    }

    function test_reentrantWithdrawDuringWithdrawIsBlocked() public {
        CallbackToken cb = new CallbackToken();
        KingOfTheHill g = new KingOfTheHill(address(cb));
        cb.mint(alice, 10_000 ether);
        cb.mint(bob, 10_000 ether);
        vm.prank(alice);
        cb.approve(address(g), type(uint256).max);
        vm.prank(bob);
        cb.approve(address(g), type(uint256).max);

        vm.prank(alice);
        g.claim(MIN);
        vm.prank(bob);
        g.claim(1_100 ether);

        // During alice's withdraw transfer, the token re-enters withdraw() for alice.
        cb.setReentrancy(address(g), abi.encodeWithSelector(KingOfTheHill.withdraw.selector));
        vm.prank(alice);
        g.withdraw();
        assertFalse(cb.reentrantOk(), "reentrant withdraw went through");
        assertEq(cb.balanceOf(alice), 10_000 ether - MIN + MIN + 55 ether);
        assertEq(cb.balanceOf(address(g)), g.pot());
    }

    function test_reentrantClaimDuringClaimIsBlocked() public {
        CallbackToken cb = new CallbackToken();
        KingOfTheHill g = new KingOfTheHill(address(cb));
        cb.mint(alice, 10_000 ether);
        vm.prank(alice);
        cb.approve(address(g), type(uint256).max);

        // During alice's claim transfer, the token re-enters claim() on her behalf (msg.sender = token).
        cb.setReentrancy(address(g), abi.encodeWithSelector(KingOfTheHill.claim.selector, 2_000 ether));
        vm.prank(alice);
        g.claim(MIN);
        assertFalse(cb.reentrantOk(), "reentrant claim went through");
        assertEq(g.king(), alice);
        assertEq(g.kingPayment(), MIN);
        assertEq(g.pot(), MIN);
        assertEq(cb.balanceOf(address(g)), MIN);
    }

    function test_reentrantSettleDuringClaimIsBlocked() public {
        CallbackToken cb = new CallbackToken();
        KingOfTheHill g = new KingOfTheHill(address(cb));
        cb.mint(alice, 10_000 ether);
        cb.mint(bob, 10_000 ether);
        vm.prank(alice);
        cb.approve(address(g), type(uint256).max);
        vm.prank(bob);
        cb.approve(address(g), type(uint256).max);
        vm.prank(alice);
        g.claim(MIN);

        vm.warp(START + DAY - 1);
        cb.setReentrancy(address(g), abi.encodeWithSelector(KingOfTheHill.settle.selector));
        vm.prank(bob);
        g.claim(1_100 ether);
        assertFalse(cb.reentrantOk(), "reentrant settle went through");
        assertEq(g.round(), 1);
        assertEq(g.king(), bob);
    }

    // ----------------------------------------------------------------------------------------------
    // Chains of claims: conservation, the pot identity and the last king's loss
    // ----------------------------------------------------------------------------------------------

    function test_singleClaimantWinsBackExactlyTheirPayment() public {
        _claim(alice, 3_000 ether);
        vm.warp(START + DAY);
        game.settle();
        assertEq(game.withdrawable(alice), 3_000 ether);
        vm.prank(alice);
        game.withdraw();
        assertEq(token.balanceOf(alice), 10_000_000 ether);
        assertEq(token.balanceOf(address(game)), 0);
    }

    function test_longChainOfExactClaimsLeavesLastKingAboutHalf() public {
        address[2] memory players = [alice, bob];
        uint256 amount = MIN;
        uint256 bonuses;
        for (uint256 i; i < 60; ++i) {
            address who = players[i % 2];
            amount = i == 0 ? MIN : game.minNextClaim();
            if (amount > token.balanceOf(who)) break;
            _claim(who, amount);
            if (i != 0) bonuses += amount * 5 / 100;
            assertEq(game.pot(), game.kingPayment() - bonuses, "pot identity");
        }
        uint256 payment = game.kingPayment();
        address last = game.king();
        uint256 potBefore = game.pot();
        uint256 creditBefore = game.withdrawable(last);
        vm.warp(block.timestamp + DAY);
        game.settle();
        uint256 prize = game.withdrawable(last) - creditBefore;
        assertEq(prize, potBefore);
        // The last king gets the pot, which is strictly less than what they paid.
        assertLt(prize, payment);
        // After a long chain of exact 110% claims the pot converges to roughly 45% of the last payment.
        assertGt(prize * 100, payment * 44);
        assertLt(prize * 100, payment * 47);
    }

    function testFuzz_claimChainConservesFunds(uint256 seed, uint8 length) public {
        length = uint8(bound(length, 1, 40));
        address[3] memory players = [alice, bob, carol];
        uint256 bonuses;
        uint256 paidIn;
        uint256 last = 0;
        for (uint256 i; i < length; ++i) {
            uint256 pick = uint256(keccak256(abi.encode(seed, i, "who"))) % 3;
            if (players[pick] == game.king()) pick = (pick + 1) % 3;
            address who = players[pick];

            uint256 minimum = game.minNextClaim();
            // Between the minimum and 3x the minimum, so chains stay affordable.
            uint256 amount = minimum + uint256(keccak256(abi.encode(seed, i, "amt"))) % (2 * minimum + 1);
            if (amount > token.balanceOf(who)) break;

            uint256 hop = uint256(keccak256(abi.encode(seed, i, "t"))) % DAY; // strictly before the deadline
            vm.warp(block.timestamp + hop);

            _claim(who, amount);
            paidIn += amount;
            if (i != 0) bonuses += amount * 5 / 100;
            last = i;

            assertEq(game.king(), who);
            assertEq(game.kingPayment(), amount);
            assertEq(game.pot(), amount - bonuses, "pot == kingPayment - bonuses this round");
            assertEq(
                token.balanceOf(address(game)),
                game.withdrawable(alice) + game.withdrawable(bob) + game.withdrawable(carol) + game.pot(),
                "held == credits + pot"
            );
        }
        last;

        vm.warp(block.timestamp + DAY);
        game.settle();
        assertEq(token.balanceOf(address(game)), paidIn);
        assertEq(
            token.balanceOf(address(game)), game.withdrawable(alice) + game.withdrawable(bob) + game.withdrawable(carol)
        );

        uint256 paidOut;
        for (uint256 i; i < 3; ++i) {
            uint256 credit = game.withdrawable(players[i]);
            if (credit == 0) continue;
            vm.prank(players[i]);
            game.withdraw();
            paidOut += credit;
        }
        assertEq(paidOut, paidIn, "payouts equal payments");
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol), 30_000_000 ether);
    }

    function testFuzz_minimumIsCeilOf110Percent(uint256 payment) public {
        payment = bound(payment, MIN, 5_000_000 ether);
        _claim(alice, payment);
        uint256 minimum = game.minNextClaim();
        assertEq(minimum, ceil110(payment));
        // minimum is the smallest integer m with m * 100 >= payment * 110.
        assertGe(minimum * 100, payment * 110);
        assertLt((minimum - 1) * 100, payment * 110);

        vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.BelowMinimum.selector, minimum - 1, minimum));
        _claim(bob, minimum - 1);
        _claim(bob, minimum);

        // The remainder after paying the dethroned king is never negative and at least 4.5% of payment.
        uint256 bonus = minimum * 5 / 100;
        uint256 remainder = minimum - payment - bonus;
        assertGe(remainder * 1000, payment * 45 - 1000);
        assertEq(game.pot(), payment + remainder);
    }

    function testFuzz_dethronedKingAlwaysProfits(uint256 payment, uint256 raise) public {
        payment = bound(payment, MIN, 1_000_000 ether);
        _claim(alice, payment);
        uint256 amount = bound(raise, game.minNextClaim(), 9_000_000 ether);
        _claim(bob, amount);
        assertGt(game.withdrawable(alice), payment);
        assertEq(game.withdrawable(alice), payment + amount * 5 / 100);
        assertEq(game.pot() + game.withdrawable(alice), payment + amount);
    }

    function testFuzz_claimTimingBoundary(uint256 offset) public {
        offset = bound(offset, 0, 3 * DAY);
        _claim(alice, MIN);
        vm.warp(START + offset);
        if (offset < DAY) {
            _claim(bob, 1_100 ether);
            assertEq(game.king(), bob);
            vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.RoundActive.selector, START + offset + DAY));
            game.settle();
        } else {
            vm.expectRevert(abi.encodeWithSelector(KingOfTheHill.RoundOver.selector, START + DAY));
            _claim(bob, 1_100 ether);
            game.settle();
            assertEq(game.round(), 2);
            assertEq(game.withdrawable(alice), MIN);
        }
    }
}
