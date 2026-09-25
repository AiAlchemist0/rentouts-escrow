// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// TEMPORARY review file. Delete before returning.
import {RentoutsSubnamesForkTest} from "./RentoutsSubnames.fork.t.sol";
import {RentoutsSubnames} from "../src/RentoutsSubnames.sol";
import {RegistryRoles, ResolverRoles, IPermissionedResolver} from "../src/interfaces/IENSv2.sol";

interface IUnsafe {
    function unsafeTransfer(address to, uint256 tokenId, bytes calldata data) external;
    function register(string memory, address, address, address, uint256, uint64) external returns (uint256);
}

contract NoReceiver {}

contract TmpCov is RentoutsSubnamesForkTest {
    bytes4 constant UNSAFE_UNTIL_EMANCIPATED = bytes4(keccak256("TransferUnsafeUntilRegistryIsEmancipated()"));

    // 1. The existing soulbound test reverts for the wrong reason.
    function test_tmp_SafeTransferRevertReasonIsEmancipationNotSoulbound() public {
        uint256 tokenId = _claim(alice, "alice");
        vm.prank(alice);
        vm.expectRevert(UNSAFE_UNTIL_EMANCIPATED);
        registry.safeTransferFrom(alice, bob, tokenId, 1, "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("TransferDisallowed(uint256,address)", tokenId, alice));
        IUnsafe(address(registry)).unsafeTransfer(bob, tokenId, "");
        assertEq(registry.getOwner(_id("alice")), alice);
    }

    // 1b. Control: a TRANSFERABLE token (holder has ROLE_CAN_TRANSFER_ADMIN) still fails safeTransferFrom,
    //     so test_SoulboundTransferReverts would pass even if soulbound were broken.
    function test_tmp_ControlTransferableTokenAlsoFailsSafeTransfer() public {
        vm.prank(deployer);
        uint256 tokenId = IUnsafe(address(registry)).register(
            "ctrl", alice, address(0), address(resolver), RegistryRoles.ROLE_CAN_TRANSFER_ADMIN, uint64(block.timestamp) + 1 days
        );
        vm.prank(alice);
        vm.expectRevert(UNSAFE_UNTIL_EMANCIPATED);
        registry.safeTransferFrom(alice, bob, tokenId, 1, "");

        vm.prank(alice);
        IUnsafe(address(registry)).unsafeTransfer(bob, tokenId, "");
        assertEq(registry.getOwner(_id("ctrl")), bob, "unsafeTransfer moves a transferable token");
    }

    // 2. Expiry: label becomes AVAILABLE in ENS but RentoutsSubnames still maps it to alice.
    function test_tmp_ExpiryLetsSomeoneElseInheritCredential() public {
        vm.startPrank(deployer);
        RentoutsSubnames sub = new RentoutsSubnames(registry, resolver, PARENT, 1 days, deployer);
        registry.grantRootRoles(
            RegistryRoles.ROLE_REGISTRAR | RegistryRoles.ROLE_UNREGISTER | RegistryRoles.ROLE_RENEW, address(sub)
        );
        resolver.grantRootRoles(ResolverRoles.ROLE_SET_ADDRESS | ResolverRoles.ROLE_SET_TEXT, address(sub));
        sub.setIssuer(issuer, true);
        vm.stopPrank();

        vm.prank(alice);
        sub.register("alice", alice);
        vm.prank(issuer);
        sub.setCredential("alice", "rentouts.leasesCompleted", "3");

        vm.warp(block.timestamp + 1 days + 1);
        assertEq(registry.getOwner(_id("alice")), address(0), "ENS: expired");
        assertEq(sub.holderOf(_id("alice")), alice, "contract: still alice");

        // issuer can no longer revoke (unregister reverts LabelExpired) -> whole revoke reverts
        vm.prank(issuer);
        vm.expectRevert();
        sub.revoke("alice", "late");

        // bob takes the label and inherits alice's issuer-written history
        vm.prank(bob);
        sub.register("alice", bob);
        string memory name = string.concat("alice.", PARENT, ".eth");
        assertEq(_addr(name), bob);
        assertEq(_text(name, "rentouts.leasesCompleted"), "3", "bob inherited alice's credential");

        // alice is stuck and nameOf(alice) now points at bob's name
        assertEq(sub.nameOf(alice), name);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.AlreadyHasName.selector, alice));
        sub.register("alice-2", alice);
    }

    // 3. transferAdmin: old admin keeps issuer power; new admin is not an issuer.
    function test_tmp_TransferAdminLeavesOldAdminIssuer() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(deployer);
        subnames.transferAdmin(newAdmin);
        assertEq(subnames.admin(), newAdmin);
        assertTrue(subnames.isIssuer(deployer), "old admin still issuer");
        assertFalse(subnames.isIssuer(newAdmin), "new admin not issuer");

        _claim(alice, "alice");
        vm.prank(deployer); // demoted admin can still revoke anyone
        subnames.revoke("alice", "old admin");
        assertTrue(subnames.retired(_id("alice")));
    }

    // 4. Issuer pre-registers for bob; bob then cannot claim in the wizard; revoke burns label forever.
    function test_tmp_IssuerPreRegisterThenHolderClaim() public {
        vm.prank(issuer);
        subnames.register("bob", bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.AlreadyHasName.selector, bob));
        subnames.register("bob", bob);
        vm.prank(bob);
        subnames.setProfileText("bob", "description", "hi");

        vm.prank(issuer);
        subnames.revoke("bob", "rehearsal");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.LabelRetired.selector, "bob"));
        subnames.register("bob", bob);
    }

    // 5. Direct-resolver issuer path: default record (name 0x00) and revoked names.
    function test_tmp_IssuerDefaultRecordLeaksToUnclaimedNames() public {
        vm.prank(issuer);
        resolver.setText(hex"00", "rentouts.onTimeRate", "100");
        assertEq(_text(string.concat("ghost.", PARENT, ".eth"), "rentouts.onTimeRate"), "100");
    }

    function test_tmp_IssuerCanWriteRevokedName() public {
        _claim(alice, "alice");
        vm.prank(issuer);
        subnames.revoke("alice", "x");
        bytes memory dns = subnames.dnsName("alice");
        vm.prank(issuer);
        resolver.setText(dns, "rentouts.onTimeRate", "100");
        assertEq(_text(string.concat("alice.", PARENT, ".eth"), "rentouts.onTimeRate"), "100");
    }

    // 6. Exact revert reasons for currently-bare expectRevert()s.
    function test_tmp_ExactReverts() public {
        _claim(alice, "alice");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("LabelAlreadyRegistered(string)", "alice"));
        subnames.register("alice", bob);

        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(registry).call(abi.encodeWithSignature("setResolver(uint256,address)", _id("alice"), mallory));
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(keccak256("EACUnauthorizedAccountRoles(uint256,uint256,address)")));

        vm.prank(alice);
        (ok, ret) = address(registry).call(abi.encodeWithSignature("unregister(uint256)", _id("alice")));
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(keccak256("EACUnauthorizedAccountRoles(uint256,uint256,address)")));
    }

    // 7. Credential-key prefix edges.
    function test_tmp_KeyPrefixEdges() public {
        _claim(alice, "alice");
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotCredentialKey.selector, "rentouts."));
        subnames.setCredential("alice", "rentouts.", "x");

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.NotCredentialKey.selector, "rentouts.status"));
        subnames.setProfileKey("rentouts.status", true);

        vm.prank(deployer);
        subnames.setProfileKey("rentouts.", true); // exact prefix is NOT a credential key
        vm.prank(alice);
        subnames.setProfileText("alice", "rentouts.", "self-written");
    }

    // 8. Frontend availability heuristic: revoked label has null addr but register reverts.
    function test_tmp_RevokedLabelLooksFreeButIsRetired() public {
        _claim(alice, "alice");
        vm.prank(issuer);
        subnames.revoke("alice", "x");
        assertEq(_addr(string.concat("alice.", PARENT, ".eth")), address(0), "getEnsAddress -> null");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RentoutsSubnames.LabelRetired.selector, "alice"));
        subnames.register("alice", bob);
    }

    // gas for the one claim tx
    function test_tmp_ClaimGas() public {
        vm.prank(alice);
        uint256 g = gasleft();
        subnames.register("alice", alice);
        emit log_named_uint("register gas (warm-ish, excl. 21k base)", g - gasleft());
    }
}

/// Run with FOUNDRY_EVM_VERSION=prague (Sepolia is post-Pectra; foundry.toml pins cancun).
contract TmpCov7702 is RentoutsSubnamesForkTest {
    address constant METAMASK_7702_DELEGATOR = 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B;
    address constant FORGE_ALICE = 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6; // live 7702 -> empty code

    function test_tmp7702_DelegatedToNoReceiverCannotClaim() public {
        (address eoa, uint256 pk) = makeAddrAndKey("tmp.7702.noreceiver");
        vm.signAndAttachDelegation(address(new NoReceiver()), pk);
        vm.prank(eoa);
        vm.expectRevert();
        subnames.register("sevenseven", eoa);
    }

    function test_tmp7702_LiveForgeAliceCannotClaim() public {
        vm.prank(FORGE_ALICE);
        vm.expectRevert();
        subnames.register("forgealice", FORGE_ALICE);
    }

    function test_tmp7702_MetaMaskSmartAccountCanClaim() public {
        (address eoa, uint256 pk) = makeAddrAndKey("tmp.7702.metamask");
        vm.signAndAttachDelegation(METAMASK_7702_DELEGATOR, pk);
        vm.prank(eoa);
        subnames.register("mmaccount", eoa);
        assertEq(registry.getOwner(_id("mmaccount")), eoa);
    }
}
