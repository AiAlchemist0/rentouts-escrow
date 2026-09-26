// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AllOfHumanGate} from "../src/AllOfHumanGate.sol";
import {EnsCredentialGate} from "../src/EnsCredentialGate.sol";
import {HumanGate} from "../src/HumanGate.sol";
import {WorldIdV4Gate} from "../src/WorldIdV4Gate.sol";
import {IRentEscrow} from "../src/interfaces/IRentEscrow.sol";
import {DeployEnsWorldGate} from "../script/DeployEnsWorldGate.s.sol";

/// @dev The RentoutsSubnames calls this test makes (the ENS contracts live in the separate ens/
///      Foundry project).
interface IRentoutsSubnamesIssuer {
    function labelOf(address holder) external view returns (string memory);
    function isIssuer(address account) external view returns (bool);
    function register(string calldata label, address holder) external returns (uint256 tokenId);
    function revoke(string calldata label, string calldata reason) external;
}

/// @dev ENSv2 UserRegistry (rentouts.eth's subregistry): 0 = the label was never registered.
interface IUserRegistryExpiry {
    function getExpiry(uint256 anyId) external view returns (uint64);
}

/// @notice The go-live of the combined gate, rehearsed on a fork of the LIVE Ethereum Sepolia contracts
///         (nothing is broadcast). It deploys EnsCredentialGate + AllOfHumanGate through
///         script/DeployEnsWorldGate.s.sol, then, as the real HumanGate owner, calls
///         setVerifier(allOfHumanGate), funds a real lease as alice.rentouts.eth and rolls back with
///         setVerifier(WorldIdV4Gate #2).
///
///         alice's two credentials are the REAL on-chain ones, not cheats: her World ID registration on
///         WorldIdV4Gate #2 (register tx 0xdbbfc6dd…8908, block 11783569) and alice.rentouts.eth. Her
///         own Sepolia USDC pays for the lease while she has enough. The only simulated states are the
///         two counter-examples, which have no real wallet on Sepolia:
///           - a World-registered wallet with no rentouts.eth name: `register` needs the RP signer's
///             signature, so this writes WorldIdV4Gate's `_verified` mapping instead (storage slot 1,
///             see `forge inspect WorldIdV4Gate storageLayout`; checked against alice's real slot);
///           - a named wallet with no World ID: it claims a fresh rentouts.eth name on the fork
///             (self-serve RentoutsSubnames.register, as the app does).
///         RPC: SEPOLIA_RPC_URL, else the public node. Skip offline with --no-match-contract Fork.
contract EnsWorldGateForkTest is Test {
    address constant RENT_ESCROW = 0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18;
    address constant HUMAN_GATE = 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd;
    /// @dev WorldIdV4Gate #2, action `fund-lease-wallet`: HumanGate's live verifier since tx
    ///      0xcd93549e…b86671 (block 11783640). It replaced gate #1 0x27052bD6…B209 (action `fund-lease`,
    ///      0 registrations).
    address constant WORLD_GATE = 0x5Cb885E6292003492932f3fa647A9d6Bf8A4aABa;
    address constant WORLD_RP_SIGNER = 0xbb80c666Ed8E8B5ec45481f911c7a892f8A842CA;
    address constant SUBNAMES = 0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60;
    address constant USER_REGISTRY = 0xD2D122000D4725a863376EcAe4220BC20590f382;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /// @dev Deployer: HumanGate owner, allowlisted landlord (LeaseShare1155) and subnames issuer.
    address constant DEPLOYER = 0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE;
    /// @dev alice.rentouts.eth, the demo tenant.
    address constant ALICE = 0x484811c8c967809bE644A89d677933c29fb9e936;
    /// @dev WorldIdV4Gate storage: slot 0 nullifierUsed, slot 1 _verified.
    uint256 constant WORLD_VERIFIED_SLOT = 1;
    /// @dev Circle USDC (FiatTokenV2_2) balanceAndBlacklistStates mapping (checked in _setUsdcBalance).
    uint256 constant USDC_BALANCE_SLOT = 9;
    /// @dev A label nobody holds on Sepolia (setUp checks it is free), for the named-but-not-World wallet.
    string constant NAMED_ONLY_LABEL = "ensworld-fork-named";

    uint128 constant DEPOSIT = 1e6; // 1 USDC
    uint128 constant RENT = 25e4; // 0.25 USDC per period
    uint32 constant PERIOD = 60;
    uint16 constant PERIODS = 2;
    uint256 constant TOTAL = uint256(DEPOSIT) + uint256(RENT) * PERIODS;

    IRentEscrow escrow = IRentEscrow(RENT_ESCROW);
    HumanGate humanGate = HumanGate(HUMAN_GATE);
    WorldIdV4Gate world = WorldIdV4Gate(WORLD_GATE);
    IRentoutsSubnamesIssuer subnames = IRentoutsSubnamesIssuer(SUBNAMES);

    EnsCredentialGate ensGate;
    AllOfHumanGate composite;

    // Unique labels: well-known makeAddr names can carry EIP-7702 code on Sepolia.
    address worldOnly = makeAddr("rentouts.ensworld.fork.worldonly"); // World ID, no rentouts.eth name
    address namedOnly = makeAddr("rentouts.ensworld.fork.namedonly"); // rentouts.eth name, no World ID
    address stranger = makeAddr("rentouts.ensworld.fork.stranger"); // neither

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
        // Pin the live assumptions this test builds on. No cheat has run yet.
        assertEq(escrow.humanGate(), HUMAN_GATE, "escrow gate");
        assertEq(humanGate.owner(), DEPLOYER, "HumanGate owner");
        assertEq(keccak256(bytes(subnames.labelOf(ALICE))), keccak256("alice"), "alice.rentouts.eth");
        assertTrue(world.isVerified(ALICE), "alice is registered on WorldIdV4Gate #2 (tx 0xdbbfc6dd)");
        assertEq(
            vm.load(WORLD_GATE, _worldSlot(ALICE)), bytes32(uint256(1)), "_verified is slot 1 (alice's real entry)"
        );
        for (uint256 i; i < 3; ++i) {
            address a = [worldOnly, namedOnly, stranger][i];
            assertFalse(world.isVerified(a), "fresh wallet not World-registered");
            assertEq(bytes(subnames.labelOf(a)).length, 0, "fresh wallet has no name");
        }
        assertEq(
            IUserRegistryExpiry(USER_REGISTRY).getExpiry(uint256(keccak256(bytes(NAMED_ONLY_LABEL)))),
            0,
            "test label never registered"
        );

        DeployEnsWorldGate script = new DeployEnsWorldGate();
        assertEq(script.DEFAULT_WORLD_GATE(), WORLD_GATE, "script default WORLD_GATE is gate #2");
        assertEq(script.DEFAULT_SUBNAMES(), SUBNAMES, "script default ENS_SUBNAMES");
        assertEq(script.DEFAULT_HUMAN_GATE(), HUMAN_GATE, "script default HUMAN_GATE");
        (ensGate, composite) = script.deploy(DEPLOYER, WORLD_GATE, SUBNAMES, HUMAN_GATE);
        assertEq(composite.gates()[0], WORLD_GATE, "composite gate 0 is WorldIdV4Gate #2");
        assertEq(composite.gates()[1], address(ensGate), "composite gate 1 is EnsCredentialGate");
    }

    // ------------------------------------------------------------------ helpers

    function _worldSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, WORLD_VERIFIED_SLOT));
    }

    /// @dev Simulates WorldIdV4Gate.register(account, …) for a wallet with no real registration.
    function _simulateWorldRegister(address account) internal {
        vm.store(WORLD_GATE, _worldSlot(account), bytes32(uint256(1)));
        assertTrue(world.isVerified(account), "World slot");
    }

    /// @dev A real self-serve claim of `<label>.rentouts.eth`, on the fork.
    function _claimName(address account, string memory label) internal {
        vm.prank(account);
        subnames.register(label, account);
        assertEq(keccak256(bytes(subnames.labelOf(account))), keccak256(bytes(label)), "name claimed");
    }

    /// @dev forge-std's deal cannot find Circle FiatTokenV2_2's balance slot (it packs a blacklist
    ///      bit into `balanceAndBlacklistStates`, slot 9), so write it directly and check it took.
    function _setUsdcBalance(address account, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(account, USDC_BALANCE_SLOT)), bytes32(amount));
        assertEq(IERC20(USDC).balanceOf(account), amount, "USDC balance slot");
    }

    /// @dev The owner's one go-live tx: HumanGate.setVerifier(allOfHumanGate).
    function _plugIn() internal {
        address previous = address(humanGate.verifier());
        vm.expectEmit(true, true, false, false, HUMAN_GATE);
        emit HumanGate.VerifierUpdated(previous, address(composite));
        vm.prank(humanGate.owner());
        humanGate.setVerifier(address(composite));
        assertEq(address(humanGate.verifier()), address(composite));
    }

    /// @dev The owner's rollback tx: HumanGate.setVerifier(WorldIdV4Gate #2).
    function _rollBack() internal {
        vm.expectEmit(true, true, false, false, HUMAN_GATE);
        emit HumanGate.VerifierUpdated(address(composite), WORLD_GATE);
        vm.prank(humanGate.owner());
        humanGate.setVerifier(WORLD_GATE);
        assertEq(address(humanGate.verifier()), WORLD_GATE);
    }

    /// @dev The deployer (an allowlisted landlord) lists a lease for `tenant`; the tenant approves it.
    ///      USDC is only topped up if the tenant's real balance is short.
    function _lease(address tenant) internal returns (uint256 leaseId) {
        vm.prank(DEPLOYER);
        leaseId = escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        if (IERC20(USDC).balanceOf(tenant) < TOTAL) _setUsdcBalance(tenant, TOTAL);
        vm.prank(tenant);
        IERC20(USDC).approve(RENT_ESCROW, TOTAL);
    }

    function _fundAndCheck(address tenant, uint256 leaseId) internal {
        uint256 escrowBefore = IERC20(USDC).balanceOf(RENT_ESCROW);
        uint256 tenantBefore = IERC20(USDC).balanceOf(tenant);
        vm.prank(tenant);
        escrow.fundLease(leaseId);
        assertEq(uint256(escrow.getLease(leaseId).state), uint256(IRentEscrow.State.ACTIVE), "ACTIVE");
        assertEq(escrow.escrowBalance(leaseId), TOTAL, "escrowed");
        assertEq(IERC20(USDC).balanceOf(RENT_ESCROW), escrowBefore + TOTAL, "escrow USDC");
        assertEq(IERC20(USDC).balanceOf(tenant), tenantBefore - TOTAL, "tenant USDC");
    }

    function _expectRefused(address tenant, uint256 leaseId) internal {
        vm.prank(tenant);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, tenant));
        escrow.fundLease(leaseId);
        assertEq(uint256(escrow.getLease(leaseId).state), uint256(IRentEscrow.State.CREATED), "still CREATED");
    }

    // ------------------------------------------------------------------ the live state, read as is

    /// @dev Where the switch starts: HumanGate -> WorldIdV4Gate #2, alice registered on it. Also passes
    ///      after a real go-live, when the verifier is an AllOfHumanGate whose first gate is #2.
    function test_Fork_LiveState_Gate2IsVerifier_AliceRegistered() public {
        address live = address(humanGate.verifier());
        if (live != WORLD_GATE) {
            assertEq(AllOfHumanGate(live).gates()[0], WORLD_GATE, "live verifier: gate #2 or AllOf[gate #2, ...]");
        }
        assertEq(world.signer(), WORLD_RP_SIGNER, "gate #2 RP signer");
        assertEq(world.actionHash(), bytes32(uint256(keccak256("fund-lease-wallet")) >> 8), "gate #2 action");
        assertTrue(humanGate.isVerified(ALICE), "alice may fund today");
        assertFalse(humanGate.isVerified(stranger), "an unregistered wallet may not");
    }

    function test_Fork_EnsGate_LiveCredential() public {
        assertEq(address(ensGate.registry()), USER_REGISTRY, "live UserRegistry");
        assertTrue(ensGate.isVerified(ALICE), "alice.rentouts.eth is active");
        assertFalse(ensGate.isVerified(stranger), "random address has no name");
        assertFalse(ensGate.isVerified(address(0)));
    }

    /// @dev The combined gate's truth table. alice's row uses only real on-chain state.
    function test_Fork_Composite_WorldAndEns() public {
        uint256 before = gasleft();
        bool aliceOk = composite.isVerified(ALICE);
        emit log_named_uint("composite.isVerified(alice) gas", before - gasleft());
        assertTrue(aliceOk, "alice: World (real) + ENS (real)");

        _simulateWorldRegister(worldOnly);
        assertFalse(ensGate.isVerified(worldOnly));
        assertFalse(composite.isVerified(worldOnly), "World only: not enough");

        _claimName(namedOnly, NAMED_ONLY_LABEL);
        assertTrue(ensGate.isVerified(namedOnly));
        assertFalse(world.isVerified(namedOnly));
        assertFalse(composite.isVerified(namedOnly), "ENS only: not enough");

        assertFalse(composite.isVerified(stranger), "neither");
    }

    // ------------------------------------------------------------------ go-live on the live escrow

    /// @dev setVerifier(composite), then alice funds a real lease with her real World ID + name.
    function test_Fork_EndToEnd_AliceFunds() public {
        _plugIn();
        assertTrue(humanGate.isVerified(ALICE));
        _fundAndCheck(ALICE, _lease(ALICE));
    }

    function test_Fork_WorldOnlyWallet_Reverts() public {
        _plugIn();
        _simulateWorldRegister(worldOnly); // a real human per World ...
        assertFalse(ensGate.isVerified(worldOnly)); // ... with no rentouts.eth name
        _expectRefused(worldOnly, _lease(worldOnly));
    }

    function test_Fork_NamedButNotWorldRegistered_Reverts() public {
        _plugIn();
        _claimName(namedOnly, NAMED_ONLY_LABEL); // an active rentouts.eth name ...
        assertFalse(world.isVerified(namedOnly)); // ... and no World ID
        _expectRefused(namedOnly, _lease(namedOnly));
    }

    /// @dev "Remove ENS and funding stops": the live issuer revokes alice.rentouts.eth.
    function test_Fork_RevokedName_StopsFunding() public {
        _plugIn();
        assertTrue(humanGate.isVerified(ALICE));
        uint256 leaseId = _lease(ALICE);

        assertTrue(subnames.isIssuer(DEPLOYER), "deployer is a live issuer");
        vm.prank(DEPLOYER);
        subnames.revoke("alice", "fork test");
        assertFalse(ensGate.isVerified(ALICE), "revoked");
        assertTrue(world.isVerified(ALICE), "World ID untouched");

        _expectRefused(ALICE, leaseId);
    }

    /// @dev Rollback is one owner tx, setVerifier(WorldIdV4Gate #2): World ID alone again. The
    ///      nameless World-registered wallet funds; the named wallet without World ID still cannot.
    function test_Fork_Rollback_ToGate2() public {
        _plugIn();
        _simulateWorldRegister(worldOnly);
        _claimName(namedOnly, NAMED_ONLY_LABEL);
        uint256 worldOnlyLease = _lease(worldOnly);
        uint256 namedOnlyLease = _lease(namedOnly);
        _expectRefused(worldOnly, worldOnlyLease);

        _rollBack();
        _fundAndCheck(worldOnly, worldOnlyLease);
        _expectRefused(namedOnly, namedOnlyLease);
        _fundAndCheck(ALICE, _lease(ALICE));
    }
}
