// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract DeployTest is Test {
    Deploy internal deployer;

    function setUp() public {
        deployer = new Deploy();
    }

    function test_deployBindsGameToFreshToken() public {
        Deploy.Deployment memory d = deployer.deploy();
        assertEq(d.game.token(), address(d.token));
        assertEq(d.token.totalSupply(), 10 ** 27);
        // The script contract is msg.sender for the constructor, so it holds the supply here. On the
        // network the factory is msg.sender and holds it instead.
        assertEq(d.token.balanceOf(address(deployer)), 10 ** 27);
        assertEq(d.token.balanceOf(address(d.game)), 0);
        assertEq(d.game.round(), 1);
        assertEq(d.game.king(), address(0));
    }

    function test_checkChainAcceptsTargetsAndDryRun() public view {
        deployer.checkChain(0, 1);
        deployer.checkChain(0, 11_155_111);
        deployer.checkChain(11_155_111, 11_155_111);
        deployer.checkChain(31_337, 31_337);
    }

    function test_checkChainRejectsMismatchAndOtherChains() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedChain.selector, 11_155_111, 1));
        deployer.checkChain(11_155_111, 1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        deployer.checkChain(1, 1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 8453));
        deployer.checkChain(8453, 8453);
    }
}
