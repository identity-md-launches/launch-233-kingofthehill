// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.prank(deployer);
        token = new LaunchToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Crown");
        assertEq(token.symbol(), "CRWN");
        assertEq(token.decimals(), 18);
    }

    function test_supplyMintedOnceToDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.TOTAL_SUPPLY(), 10 ** 27);
        assertEq(token.balanceOf(deployer), 10 ** 27);
    }

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1_234 ether));
        assertEq(token.balanceOf(alice), 1_234 ether);
        assertEq(token.balanceOf(deployer), 10 ** 27 - 1_234 ether);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transfer(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice), token.totalSupply());
    }

    function test_transferAboveBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_noMintOrAdminSelectors() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer, uint256(1)));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), 10 ** 27, signatures[i]);
        }
    }
}
