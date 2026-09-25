// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// TEMPORARY review test. Delete before returning.
import {console2} from "forge-std/Test.sol";
import {RentoutsSubnamesForkTest} from "./RentoutsSubnames.fork.t.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";

contract TmpAccessReview is RentoutsSubnamesForkTest {
    // A: expiry desyncs contract state from the registry
    function test_tmp_ExpiryDesync() public {
        _claim(alice, "alice");
        string memory name = string.concat("alice.", PARENT, ".eth");
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "3");
        vm.prank(alice);
        subnames.setProfileText("alice", "description", "alice profile");

        vm.warp(block.timestamp + YEAR + 1);
        assertEq(registry.getOwner(_id("alice")), address(0), "expired in registry");
        // still resolves as an active credential via the parent's shared resolver
        assertEq(_addr(name), alice, "addr after expiry");
        assertEq(_text(name, "rentouts.status"), "active", "status after expiry");

        // issuer can no longer revoke
        vm.prank(issuer);
        vm.expectRevert();
        subnames.revoke("alice", "fraud");

        // issuer can still write credentials onto the expired name
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "4");

        // alice is locked out of a fresh name
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.AlreadyHasName.selector, alice));
        subnames.register("alice-new", alice);

        // bob takes the label and inherits alice's records; alice's mapping is stale
        vm.prank(bob);
        subnames.register("alice", bob);
        assertEq(_addr(name), bob, "addr now bob");
        assertEq(_text(name, "rentouts.leasesCompleted"), "4", "bob inherits alice credential");
        assertEq(_text(name, "description"), "alice profile", "bob inherits alice profile");
        assertEq(subnames.labelOf(alice), "alice", "alice stale label");
        assertEq(subnames.nameOf(alice), name, "alice nameOf points at bob's name");
        assertEq(subnames.holderOf(_id("alice")), bob);

        // revoking bob does not free alice
        vm.prank(issuer);
        subnames.revoke("alice", "x");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.AlreadyHasName.selector, alice));
        subnames.register("alice-new", alice);
    }

    // B: revoke leaves credential keys resolvable
    function test_tmp_RevokeLeavesCredentials() public {
        _claim(alice, "alice");
        string memory name = string.concat("alice.", PARENT, ".eth");
        bytes memory dns = subnames.dnsName("alice");
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "3");
        vm.prank(issuer);
        resolver.setText(dns, "rentouts.onTimeRate", "100");

        vm.prank(issuer);
        subnames.revoke("alice", "fraud");

        assertEq(_text(name, "rentouts.status"), "revoked");
        assertEq(_text(name, "rentouts.credential"), "tenant/v1", "credential marker survives");
        assertEq(_text(name, "rentouts.leasesCompleted"), "3", "leases survive");
        assertEq(_text(name, "rentouts.onTimeRate"), "100", "onTime survives");

        // issuer EOA can keep writing on the revoked name directly
        vm.prank(issuer);
        resolver.setText(dns, "rentouts.onTimeRate", "99");
        assertEq(_text(name, "rentouts.onTimeRate"), "99");
    }

    // C: labels ENSIP-15 rejects are accepted
    function test_tmp_DoubleHyphen() public {
        vm.prank(alice);
        subnames.register("ab--cd", alice);
        assertEq(_addr(string.concat("ab--cd.", PARENT, ".eth")), alice, "UR resolves non-normalized");
        vm.prank(bob);
        subnames.register("xn--abc", bob);
    }

    // D: default record at node 0
    function test_tmp_DefaultRecord() public {
        vm.prank(issuer);
        resolver.setText(hex"00", "rentouts.onTimeRate", "100");
        assertEq(_text(string.concat("ghost.", PARENT, ".eth"), "rentouts.onTimeRate"), "100", "ghost gets default");
        assertEq(_text(string.concat("x.alice.", PARENT, ".eth"), "rentouts.onTimeRate"), "100", "deep ghost gets default");

        // malformed "\x00<parent>" name: what does NameCoder do?
        bytes memory weird = abi.encodePacked(hex"00", subnames.parentDns());
        vm.prank(issuer);
        try resolver.setText(weird, "rentouts.onTimeRate", "55") {
            console2.log("weird name ACCEPTED");
            console2.log(_text(string.concat("ghost2.", PARENT, ".eth"), "rentouts.onTimeRate"));
        } catch {
            console2.log("weird name reverted");
        }
    }

    // E: parent records reachable by issuer key-scoped role
    function test_tmp_IssuerWritesParent() public {
        vm.prank(issuer);
        resolver.setText(subnames.parentDns(), "rentouts.onTimeRate", "1");
        assertEq(_text(string.concat(PARENT, ".eth"), "rentouts.onTimeRate"), "1");
    }
}
