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

/// @dev The one RentoutsSubnames call this test makes as the live issuer (the ENS contracts live in
///      the separate ens/ Foundry project).
interface IRentoutsSubnamesIssuer {
    function labelOf(address holder) external view returns (string memory);
    function isIssuer(address account) external view returns (bool);
    function revoke(string calldata label, string calldata reason) external;
}

/// @notice End to end against the LIVE Ethereum Sepolia contracts (fork; nothing is broadcast):
///         deploys EnsCredentialGate + AllOfHumanGate through script/DeployEnsWorldGate.s.sol, points
///         the live HumanGate at the combined gate as its owner would, and funds a real lease as
///         alice.rentouts.eth. World ID registration is simulated by writing WorldIdV4Gate's
///         `_verified` mapping (storage slot 1, see `forge inspect WorldIdV4Gate storageLayout`).
///         RPC: SEPOLIA_RPC_URL, else the public node. Skip offline with --no-match-contract Fork.
contract EnsWorldGateForkTest is Test {
    address constant RENT_ESCROW = 0x2357705A8382067d9bE9DadA2EEf70e23fa4cd18;
    address constant HUMAN_GATE = 0xFF6850c48B55d3d4a1e21b8562F15c653a3c3abd;
    address constant WORLD_GATE = 0x27052bD69b3d961940bCD093C21ba729b6c1B209;
    address constant SUBNAMES = 0xd7bDB1EeDa6AEDf59B3868D048e75cC3dBFDFf60;
    address constant USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    /// @dev Deployer: HumanGate owner, allowlisted landlord (LeaseShare1155) and subnames issuer.
    address constant DEPLOYER = 0xdD9c17ecAe9301b67De17F1ba2b5084EaC59CCCE;
    /// @dev alice.rentouts.eth, the demo tenant.
    address constant ALICE = 0x484811c8c967809bE644A89d677933c29fb9e936;
    /// @dev WorldIdV4Gate storage: slot 0 nullifierUsed, slot 1 _verified.
    uint256 constant WORLD_VERIFIED_SLOT = 1;
    /// @dev Circle USDC (FiatTokenV2_2) balanceAndBlacklistStates mapping (checked in _setUsdcBalance).
    uint256 constant USDC_BALANCE_SLOT = 9;

    uint128 constant DEPOSIT = 1e6; // 1 USDC
    uint128 constant RENT = 25e4; // 0.25 USDC per period
    uint32 constant PERIOD = 60;
    uint16 constant PERIODS = 2;

    IRentEscrow escrow = IRentEscrow(RENT_ESCROW);
    HumanGate humanGate = HumanGate(HUMAN_GATE);
    WorldIdV4Gate world = WorldIdV4Gate(WORLD_GATE);
    IRentoutsSubnamesIssuer subnames = IRentoutsSubnamesIssuer(SUBNAMES);

    EnsCredentialGate ensGate;
    AllOfHumanGate composite;

    // Unique labels: well-known makeAddr names can carry EIP-7702 code on Sepolia.
    address ensLess = makeAddr("rentouts.ensworld.fork.ensless");
    address stranger = makeAddr("rentouts.ensworld.fork.stranger");

    function setUp() public {
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("https://ethereum-sepolia-rpc.publicnode.com")));
        // Pin the live assumptions this test builds on.
        assertEq(escrow.humanGate(), HUMAN_GATE, "escrow gate");
        assertEq(keccak256(bytes(subnames.labelOf(ALICE))), keccak256("alice"), "alice.rentouts.eth");

        DeployEnsWorldGate script = new DeployEnsWorldGate();
        (ensGate, composite) = script.deploy(DEPLOYER, WORLD_GATE, SUBNAMES, HUMAN_GATE);

        // Start every test from "nobody is World-verified", whatever the live state is by then.
        _setWorld(ALICE, false);
        _setWorld(ensLess, false);
    }

    function _setWorld(address account, bool verified) internal {
        vm.store(WORLD_GATE, keccak256(abi.encode(account, WORLD_VERIFIED_SLOT)), bytes32(uint256(verified ? 1 : 0)));
        assertEq(world.isVerified(account), verified, "World slot");
    }

    /// @dev forge-std's deal cannot find Circle FiatTokenV2_2's balance slot (it packs a blacklist
    ///      bit into `balanceAndBlacklistStates`, slot 9), so write it directly and check it took.
    function _setUsdcBalance(address account, uint256 amount) internal {
        vm.store(USDC, keccak256(abi.encode(account, USDC_BALANCE_SLOT)), bytes32(amount));
        assertEq(IERC20(USDC).balanceOf(account), amount, "USDC balance slot");
    }

    function _plugIn() internal {
        vm.prank(humanGate.owner());
        humanGate.setVerifier(address(composite));
        assertEq(address(humanGate.verifier()), address(composite));
    }

    function _lease(address tenant) internal returns (uint256 leaseId) {
        vm.prank(DEPLOYER);
        leaseId = escrow.createLease(tenant, DEPOSIT, RENT, PERIOD, PERIODS);
        uint256 total = uint256(DEPOSIT) + uint256(RENT) * PERIODS;
        if (IERC20(USDC).balanceOf(tenant) < total) _setUsdcBalance(tenant, total);
        vm.prank(tenant);
        IERC20(USDC).approve(RENT_ESCROW, total);
    }

    // ------------------------------------------------------------------ the ENS half, live

    function test_Fork_EnsGate_LiveCredential() public {
        assertEq(address(ensGate.registry()), 0xD2D122000D4725a863376EcAe4220BC20590f382, "live UserRegistry");
        assertTrue(ensGate.isVerified(ALICE), "alice.rentouts.eth is active");
        assertFalse(ensGate.isVerified(stranger), "random address has no name");
        assertFalse(ensGate.isVerified(address(0)));
    }

    function test_Fork_Composite_FalseUntilWorldSaysTrue() public {
        assertFalse(composite.isVerified(ALICE), "ENS only: not enough");
        _setWorld(ALICE, true);
        uint256 before = gasleft();
        bool ok = composite.isVerified(ALICE);
        emit log_named_uint("composite.isVerified(alice) gas", before - gasleft());
        assertTrue(ok, "World + ENS");

        _setWorld(ensLess, true);
        assertFalse(composite.isVerified(ensLess), "World only: not enough");
    }

    // ------------------------------------------------------------------ end to end, live escrow

    function test_Fork_EndToEnd_AliceFundsOnlyWithWorldAndEns() public {
        _plugIn();
        uint256 leaseId = _lease(ALICE);

        // ENS name but no World ID yet: blocked
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, ALICE));
        escrow.fundLease(leaseId);

        // World ID registered: funds
        _setWorld(ALICE, true);
        uint256 total = uint256(DEPOSIT) + uint256(RENT) * PERIODS;
        uint256 escrowBefore = IERC20(USDC).balanceOf(RENT_ESCROW);
        vm.prank(ALICE);
        escrow.fundLease(leaseId);
        assertEq(uint256(escrow.getLease(leaseId).state), uint256(IRentEscrow.State.ACTIVE));
        assertEq(escrow.escrowBalance(leaseId), total);
        assertEq(IERC20(USDC).balanceOf(RENT_ESCROW), escrowBefore + total);
    }

    function test_Fork_EnsLessWallet_Reverts() public {
        _plugIn();
        _setWorld(ensLess, true); // a real human per World ...
        assertFalse(ensGate.isVerified(ensLess)); // ... with no rentouts.eth name
        uint256 leaseId = _lease(ensLess);
        vm.prank(ensLess);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, ensLess));
        escrow.fundLease(leaseId);
    }

    /// @dev "Remove ENS and funding stops": the live issuer revokes alice.rentouts.eth.
    function test_Fork_RevokedName_StopsFunding() public {
        _plugIn();
        _setWorld(ALICE, true);
        assertTrue(humanGate.isVerified(ALICE));
        uint256 leaseId = _lease(ALICE);

        assertTrue(subnames.isIssuer(DEPLOYER), "deployer is a live issuer");
        vm.prank(DEPLOYER);
        subnames.revoke("alice", "fork test");
        assertFalse(ensGate.isVerified(ALICE), "revoked");

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IRentEscrow.NotVerifiedHuman.selector, ALICE));
        escrow.fundLease(leaseId);
    }

    /// @dev Rollback is one owner tx: back to World only, and the ENS-less (World-verified) wallet funds.
    function test_Fork_Rollback_ToWorldOnly() public {
        _plugIn();
        _setWorld(ensLess, true);
        uint256 leaseId = _lease(ensLess);
        vm.prank(humanGate.owner());
        humanGate.setVerifier(WORLD_GATE);
        vm.prank(ensLess);
        escrow.fundLease(leaseId);
        assertEq(uint256(escrow.getLease(leaseId).state), uint256(IRentEscrow.State.ACTIVE));
    }
}
