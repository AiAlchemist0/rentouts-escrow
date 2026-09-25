// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CredentialSync} from "../src/CredentialSync.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {EnsForkBase} from "./EnsForkBase.sol";

/// @dev Test double: only the escrow call CredentialSync makes (tenantStats), with settable stats.
contract MockRentEscrow {
    mapping(address => IRentEscrow.TenantStats) internal _stats;

    function setStats(address tenant, IRentEscrow.TenantStats memory s) external {
        _stats[tenant] = s;
    }

    function tenantStats(address tenant) external view returns (IRentEscrow.TenantStats memory) {
        return _stats[tenant];
    }
}

/// @notice CredentialSync against live ENSv2 on a Sepolia fork: escrow stats -> rentouts.* records,
///         read back through the Universal Resolver. Nothing is broadcast.
///         Run: forge test --match-path test/CredentialSync.fork.t.sol -vv
contract CredentialSyncForkTest is EnsForkBase {
    MockRentEscrow escrow;
    CredentialSync sync;
    address keeper = makeAddr("rentouts.test.keeper"); // any address: sync is permissionless

    event Synced(address indexed tenant, string label, uint32 leasesCompleted, uint32 disputes);

    function setUp() public override {
        super.setUp();
        escrow = new MockRentEscrow();
        sync = new CredentialSync(IRentEscrow(address(escrow)), subnames);
        vm.prank(deployer); // what script phase credentialSync() does
        subnames.setIssuer(address(sync), true);
    }

    // ------------------------------------------------------------------ happy path

    function test_SyncWritesEscrowDerivedRecords() public {
        _claim(alice, "alice");
        _setStats(alice, 3, 1, 12_500_000, 1_000e6, 1_000e6);

        vm.expectEmit(address(sync));
        emit Synced(alice, "alice", 3, 1);
        vm.prank(keeper);
        sync.sync(alice);

        string memory name = _name("alice");
        assertEq(_text(name, "rentouts.leasesCompleted"), "3");
        assertEq(_text(name, "rentouts.disputes"), "1");
        assertEq(_text(name, "rentouts.rentPaid"), "12.50");
        assertEq(_text(name, "rentouts.depositReturnRate"), "100");
        string memory caip10 = string.concat("eip155:11155111:", vm.toLowercase(vm.toString(address(escrow))));
        assertEq(_text(name, "rentouts.escrow"), caip10);
        assertEq(sync.escrowAccountId(), caip10);
        // Claim-time records are untouched.
        assertEq(_text(name, "rentouts.credential"), "tenant/v1");
        assertEq(_text(name, "rentouts.status"), "active");
        assertEq(_addr(name), alice);
    }

    function test_SyncIsPermissionless() public {
        _claim(alice, "alice");
        _setStats(alice, 1, 0, 0, 0, 0);
        address[3] memory callers = [keeper, alice, mallory];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            sync.sync(alice);
        }
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "1");
    }

    function test_ResyncAfterStatsChangeUpdatesRecords() public {
        _claim(alice, "alice");
        _setStats(alice, 1, 0, 500e6, 0, 0);
        sync.sync(alice);
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "1");
        assertEq(_text(_name("alice"), "rentouts.rentPaid"), "500.00");
        assertEq(_text(_name("alice"), "rentouts.depositReturnRate"), "n/a");

        _setStats(alice, type(uint32).max, 2, 1_500e6, 2_000e6, 1_000e6);
        vm.prank(keeper);
        sync.sync(alice);
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "4294967295");
        assertEq(_text(_name("alice"), "rentouts.disputes"), "2");
        assertEq(_text(_name("alice"), "rentouts.rentPaid"), "1500.00");
        assertEq(_text(_name("alice"), "rentouts.depositReturnRate"), "50");
    }

    /// An issuer hand-edit of a derived key is undone by the next permissionless sync.
    function test_SyncRestoresOverwrittenValue() public {
        _claim(alice, "alice");
        _setStats(alice, 2, 0, 0, 0, 0);
        sync.sync(alice);
        vm.prank(issuer);
        subnames.setCredential("alice", "rentouts.leasesCompleted", "99");
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "99");

        vm.prank(keeper);
        sync.sync(alice);
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "2");
    }

    // ------------------------------------------------------------------ reverts

    function test_RevertsForTenantWithoutName() public {
        _setStats(bob, 5, 0, 0, 0, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CredentialSync.NoName.selector, bob));
        sync.sync(bob);
    }

    function test_RevertsAfterRevoke() public {
        _claim(alice, "alice");
        _setStats(alice, 1, 0, 0, 0, 0);
        sync.sync(alice);
        vm.prank(issuer);
        subnames.revoke("alice", "fraud");

        vm.expectRevert(abi.encodeWithSelector(CredentialSync.NoName.selector, alice));
        sync.sync(alice);
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "", "revoke wiped the synced record");
    }

    function test_RevertsIfNotIssuer() public {
        _claim(alice, "alice");
        _setStats(alice, 1, 0, 0, 0, 0);

        // Never made an issuer.
        CredentialSync rogue = new CredentialSync(IRentEscrow(address(escrow)), subnames);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        rogue.sync(alice);

        // Issuer rights removed by the admin.
        vm.prank(deployer);
        subnames.setIssuer(address(sync), false);
        vm.prank(keeper);
        vm.expectRevert(RentoutsSubnames.NotIssuer.selector);
        sync.sync(alice);
        assertEq(_text(_name("alice"), "rentouts.leasesCompleted"), "");
    }

    function test_ConstructorRejectsZeroAddresses() public {
        vm.expectRevert(CredentialSync.ZeroAddress.selector);
        new CredentialSync(IRentEscrow(address(0)), subnames);
        vm.expectRevert(CredentialSync.ZeroAddress.selector);
        new CredentialSync(IRentEscrow(address(escrow)), RentoutsSubnames(address(0)));
    }

    // ------------------------------------------------------------------ formatting

    function test_DepositReturnRate() public {
        _claim(alice, "alice");
        uint128[2][6] memory cases = [
            [uint128(0), uint128(0)], // no ended lease yet
            [uint128(1_000e6), uint128(1_000e6)],
            [uint128(1_000e6), uint128(500e6)],
            [uint128(3e6), uint128(2e6)], // 66.67% rounds down
            [uint128(1_000e6), uint128(0)], // deposit fully withheld
            [uint128(1_000e6), uint128(1_500e6)] // capped at 100
        ];
        string[6] memory want = ["n/a", "100", "50", "66", "0", "100"];
        for (uint256 i; i < cases.length; ++i) {
            _setStats(alice, 0, 0, 0, cases[i][0], cases[i][1]);
            sync.sync(alice);
            assertEq(_text(_name("alice"), "rentouts.depositReturnRate"), want[i]);
        }
    }

    function test_RentPaidFormatting() public {
        _claim(alice, "alice");
        uint128[8] memory units =
            [uint128(0), 1, 9_999, 10_000, 100_000, 1_234_567, 12_500_000, type(uint128).max];
        string[8] memory want = [
            "0.00",
            "0.00",
            "0.00",
            "0.01",
            "0.10",
            "1.23",
            "12.50",
            "340282366920938463463374607431768.21"
        ];
        for (uint256 i; i < units.length; ++i) {
            _setStats(alice, 0, 0, units[i], 0, 0);
            sync.sync(alice);
            assertEq(_text(_name("alice"), "rentouts.rentPaid"), want[i]);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _setStats(
        address tenant,
        uint32 completed,
        uint32 disputed,
        uint128 rentPaid,
        uint128 depositsPosted,
        uint128 depositsReturned
    ) internal {
        escrow.setStats(
            tenant,
            IRentEscrow.TenantStats({
                leasesFunded: completed,
                leasesCompleted: completed,
                leasesDisputed: disputed,
                periodsPaid: 0,
                rentPaid: rentPaid,
                depositsPosted: depositsPosted,
                depositsReturned: depositsReturned
            })
        );
    }
}
