# ENSv2 docs & ecosystem research (raw findings)

Collected 2026-09-25 ~21:30 JST by a research subagent. Sources: docs.ens.domains (ensdomains/docs @35d6483), ensdomains/contracts-v2 tag `sepolia-deployment-2026-09-15` (commit f2f0a05), npm, ensjs main. Confidence per fact. **Not yet verified on-chain** (no Sepolia RPC from the cloud VM).

## ENSv2 on Sepolia: official status

*Confidence: high*

The official ENS docs (ensdomains/docs, last updated 2026-09-17) list Sepolia as 'Sepolia (ENSv2 Beta)'. They point developers to the ENS App at https://app.ens.dev and the ENS Explorer at https://explorer.ens.dev. The old ENSv1 Sepolia contracts appear under 'Sepolia (Legacy)' with this warning: 'These ENSv1 contracts still exist on Sepolia but are no longer in use: the Universal Resolver and the ENS apps for Sepolia are linked against the ENSv2 deployment above.' The docs no longer reference sepolia.app.ens.domains for Sepolia, and they say Holesky is being phased out.

Source: https://docs.ens.domains/learn/deployments (source: github.com/ensdomains/docs src/pages/learn/deployments.mdx @35d6483, 2026-09-17)

## ENSv2 Sepolia: canonical address set

*Confidence: high*

The current Sepolia v2 deployment went out at 2026-09-15T09:46:38Z. It is recorded in contracts-v2 tag sepolia-deployment-2026-09-15 (commit f2f0a05), file contracts/deployments/sepolia/addresses.md. The docs site pins contracts-v2 commit 71a3b733, which has exactly the same address set. Key addresses: ETHRegistrar 0xabe76f6c8dfced81aa5a2bb8034202a7136b94ca; ETHRegistry 0x657ea849311d3d5823348dded7c2aaafb3ede09e; RootRegistry 0x9703dbd26dab89504490994138cf2c575251a9ce; VerifiableFactory 0x9e726eb570beb6bceb495ab8cda7df517d4e841c; UserRegistryImpl 0xa80338aaa8d23831cea25e858d1774534abb0263; PermissionedResolverImpl 0x14f09fd05d4585759e54844dc9b00147131cf243; PublicResolverV2 0xd7e590ad0e92a6ac1d81f4483a9b951d3585a50f; StandardRentPriceOracle 0x9b0b9c65bdaf9794ff7697e4dcfb1f50581072bb; MockUSDC 0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e; MockDAI 0x278053acc97888e63ec81c80fec641bf0bf19664; UniversalHelper 0x33f571aa8a160a21b877cf6e0fb8806692b97df5; UniversalResolverV2 implementation 0x5d25c1d6acbb71b7a28aa7899618a3412a8303e3, behind UpgradableUniversalResolverProxy 0xeEeEEEeE14D718C2B47D9923Deab1335E144EeEe; ENSV1Resolver (v1 mirror) 0xb2bf4a9a86d29661ea93223582b9945943931e42; ReverseRegistrarAdapter 0x39993148caa6a20ae1f08e1b2427966e97f85aab; DefaultReverseRegistrarAdapter 0x4f32a1c62e202922d4d6307126f43218db9da6f5.

Source: https://raw.githubusercontent.com/ensdomains/contracts-v2/71a3b7339dbc55ab47667abdfe8303bac4f4c24e/contracts/docs/addresses/sepolia.md ; git clone --branch sepolia-deployment-2026-09-15 https://github.com/ensdomains/contracts-v2 (local copy /tmp/claude-0/ens-research-webdocs/cv2-0915/contracts/deployments/sepolia/addresses.md)

## Verifying the prior note about UserRegistry and PermissionedResolver

*Confidence: high*

The prior note is partly right. Tag sepolia-deployment-2026-09-15 exists and is the current deployment. But 'UserRegistry' and 'PermissionedResolver' in that deployment are implementation contracts (UserRegistryImpl, PermissionedResolverImpl), not contracts you call directly. Each account deploys its own proxy through VerifiableFactory.deployProxy(impl, salt, initData). The resolver salt is keccak256('OwnedResolver', owner, version); the registry salt is keccak256('UserRegistry', namehash, version). initialize() takes a Grant[] array of (account, roleBitmap). The docs use ALL_ROLES = 0x1111...1111 as the role bitmap. Earlier tags also exist: 2026-05-28, 2026-06-29, 2026-07-31. Their addresses are different, and so are the addresses in ensjs npm v5 and in third-party kits.

Source: https://docs.ens.domains/ensv2/verifiable-factory (ensdomains/docs src/pages/ensv2/verifiable-factory.mdx); git ls-remote --tags https://github.com/ensdomains/contracts-v2.git

## How to register a .eth name on Sepolia under v2

*Confidence: high*

ETHRegistrar uses commit-reveal. Call commit(makeCommitment(label, owner, secret, subregistry, resolver, duration, referrer)), wait at least MIN_COMMITMENT_AGE (60 s), approve the ERC20, then call register(label, owner, secret, subregistry, resolver, duration, paymentToken, referrer). Check isAvailable(label) and getRegisterPrice(label, duration, token) first. Fees are paid in stablecoins, not ETH. A 5+ character name costs $8/yr, 4 characters $160/yr, 3 characters $640/yr. The grace period is 28 days. The registrant gets ROLE_SET_SUBREGISTRY(+ADMIN), ROLE_SET_RESOLVER(+ADMIN) and ROLE_CAN_TRANSFER_ADMIN.

Source: https://docs.ens.domains/ensv2/eth-registrar (src/pages/ensv2/eth-registrar.mdx @35d6483)

## Faucets and test tokens

*Confidence: high*

You need Sepolia ETH for gas (any public faucet) plus a stablecoin for the fee. ENS's MockUSDC (0x16f95d91...) has an open mint(address,uint256) that anyone can call. The docs say the registrar also accepts Circle's Sepolia USDC 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 and a test DAI. I confirmed that StandardRentPriceOracle's constructor arguments in the 09-15 deployment list all three tokens: MockUSDC, MockDAI and Circle USDC. They can be disabled later via disablePaymentToken, so check isPaymentToken on-chain.

Source: https://docs.ens.domains/ensv2/tutorial-app-developers#getting-test-funds ; https://docs.ens.domains/web/ensv2-readiness#registration-fees-are-paid-in-stablecoins ; contracts-v2@sepolia-deployment-2026-09-15 deployments/sepolia/StandardRentPriceOracle.json argsData

## Risk: MockUSDC can be burned by anyone

*Confidence: high*

ENS's MockUSDC is MockERC20 from test/mocks. Anyone can call nuke(address owner), which burns that owner's entire balance (_burn(owner, balanceOf(owner))). Do not use it as the escrow's rent or deposit token. Use it only to pay ENS registration fees. For the escrow, Circle Sepolia USDC (0x1c7D4B19...) is the safe choice, and the ENS registrar accepts it too.

Source: contracts-v2@sepolia-deployment-2026-09-15 contracts/test/mocks/MockERC20.sol lines 26-32; deployments/sepolia/MockUSDC.json ABI includes nuke(address)

## Risk: Sepolia v2 state gets reset

*Confidence: high*

ENS redeploys v2 on Sepolia from time to time, and names registered before a redeploy are lost. After the 2026-09-15 redeploy, a third-party project reported that xovi.eth and agent1.xovi.eth no longer resolved (resolver 0x0), and they had to re-register (issue opened 2026-09-17). Search-result summaries of the ENS beta announcement say state may be reset with routine deployments. The Universal Resolver proxy address 0xeEeE...EeEe stays the same, but registrar, registry and resolver implementation addresses change on each redeploy. Script the registration so it can be re-run in minutes, and never hardcode anything except the UR proxy.

Source: https://github.com/zenbitETH/xovi-agents/issues/48 ; https://ens.domains/blog/post/ensv2-beta-public-testing (via WebSearch summary; site blocked for direct fetch)

## ENS App on Sepolia

*Confidence: medium*

According to search summaries of the ENS blog, the ENS App and Explorer entered public beta on Ethereum Sepolia on 2026-08-12. The beta lets users try the v2 registry and test the v1-to-v2 upgrade flow for eligible Sepolia .eth names, and names from the earlier alpha do not carry over. The docs say to 'interact with' the Sepolia v2 deployment via app.ens.dev. I could not load app.ens.dev (blocked), so I have not confirmed that its register-new-name flow works right now.

Source: https://ens.domains/blog/post/ensv2-beta-public-testing (WebSearch summary); https://docs.ens.domains/learn/deployments

## Is Sepolia ENSv1 registration dead?

*Confidence: high*

The official docs support the claim. The migration page says: 'Once ENSv2 is live, v1 .eth registrations and renewals are disabled... Names in v1 will simply expire and can never be re-registered through v1.' The readiness page says: 'During the migration from ENSv1 to ENSv2, new registrations happen exclusively in ENSv2.' The contracts-v2 runbook for the live Sepolia v1 includes Phase 3 'disable-v1-registrars'. That phase removes the four v1 registration controllers and the old handoff contracts from BaseRegistrar. Phase 4 then transfers BaseRegistrar ownership to ETHRenewerV1 (0xd06e726e9bd8ac0f33a2a45f4cc28fe10d656a36). The docs also mark Sepolia v1 as 'no longer in use'. I could not read on-chain state from here (RPC blocked).

Source: https://docs.ens.domains/ensv2/migration (src/pages/ensv2/migration.mdx line 16, 113, 240); https://docs.ens.domains/web/ensv2-readiness ; contracts-v2@sepolia-deployment-2026-09-15 contracts/docs/migration.md (Phases table, Phase 3, 'Live deployment (Sepolia)')

## How to confirm the v1 freeze on-chain

*Confidence: medium*

To confirm directly: BaseRegistrar 0x57f1887a8BF19b14fC0dF6Fd9B2acc9Af147eA85 should return controllers(0xfb3cE5D01e0f33f41DbB39035dB9745962F1f968) == false (that is the v1 ETHRegistrarController listed in ensjs), and owner() should equal ETHRenewerV1 0xd06e726e9bd8ac0f33a2a45f4cc28fe10d656a36. Unmigrated v1 names still resolve through the ENSV1Resolver mirror (0xb2bf4a9a...). For example, the xovi issue notes that ens.eth still resolved 'through the v1 bridge'.

Source: ensjs main packages/ensjs/src/clients/l1.ts (sepolia ensEthRegistrarController); contracts-v2 migration.md Phase 3/4; https://github.com/zenbitETH/xovi-agents/issues/48

## ENSjs on npm

*Confidence: high*

@ensdomains/ensjs dist-tags: latest=4.3.1 (published 2026-06-24), alpha=5.0.0-alpha.1 (2025-11-05), sepolia-fix=5.0.0-sepolia-fix.1 (2026-05-26); next=4.2.0 is stale. Nothing has been published to npm since 2026-06-24. The v5 preview is the only npm build with v2 write helpers, and its Sepolia v2 addresses are stale: ensRegistry 0xc960f7217d..., ensEthRegistrar 0x8c2e866b..., usdc 0x3dfc8b53..., PermissionedResolverImpl 0xdce5205a..., UserRegistryImpl 0x0f99e7ea..., which do not match the 09-15 deployment. @ensdomains/ensjs-abi latest=5.0.0-sepolia-fix.1. There is no @ensdomains/contracts-v2 npm package; the docs install it with 'forge install ensdomains/contracts-v2'.

Source: npm view @ensdomains/ensjs dist-tags/time; npm pack @ensdomains/ensjs@5.0.0-sepolia-fix.1 -> src/clients/l1.ts; npm view @ensdomains/contracts-v2 (E404)

## ENSjs on GitHub main (not released)

*Confidence: high*

ensjs main (commit 4fc0c2a, 2026-09-23) points Sepolia at the 09-15 redeploy. PR #380, 'feat!: target the 2026-09-15 Sepolia v2 redeploy', was merged 2026-09-15. It replaces aliases with resolver links (linkToNode/linkToRecord), changes renew to renew(RenewData, token), adds V2 PermissionedResolver setters, and uses UniversalHelper for registry walks. PR #377 pointed Sepolia at a 'hackathon clean testnet deployment'. Main also sets ensUniversalHelper 0x33f571aa..., ensEthRenewerV1 0xd06e726e..., ensHcaFactory 0xB7CFeCEe..., the Sepolia subgraph https://v1-graphql.ens.dev/subgraph, and the V1 PublicResolver as 0x8FADE66B79cC9f707aB26799354482EB93a5B7dD.

Source: https://github.com/ensdomains/ensjs/pull/380 ; https://github.com/ensdomains/ensjs/pull/377 ; git clone https://github.com/ensdomains/ensjs (packages/ensjs/src/clients/l1.ts @4fc0c2a)

## ENSjs pitfall: contract key mismatch

*Confidence: medium*

On ensjs main, the v2 registrar actions (registrar/commitName.ts, registerName.ts) require a chain contract key named 'ethRegistrar' (and 'usdc'). The production Sepolia config in clients/l1.ts names that key 'ensEthRegistrar'; only the test helper addTestContracts.ts defines 'ethRegistrar'. With extendChainWithEns(sepolia) alone, registerName will probably fail to find the registrar address. Either add contracts.ethRegistrar = {address: 0xAbe76F6C8DFcEd81AA5A2bB8034202A7136b94ca} by hand, or call the registrar with plain viem writeContract.

Source: ensjs main packages/ensjs/src/actions/wallet/registrar/registerName.ts:59, src/clients/l1.ts, src/test/addTestContracts.ts:136

## viem ENS support

*Confidence: high*

viem latest is 2.56.9 (published 2026-09-24; next=3.0.0-next.10). Its sepolia chain definition sets ensUniversalResolver = 0xeeeeeeee14d718c2b47d9923deab1335e144eeee (blockCreated 8,928,790), the v2 UR proxy. ENS readiness minimums: viem >= 2.35.0, ENSjs >= 4.2.3, ethers >= 6.17.0, web3.py >= 7.16.0, alloy-rs >= 2.4.2. For reads (getEnsAddress, getEnsText, getEnsName, getEnsResolver), plain viem on sepolia works with no address configuration. ENS says not to hardcode a UR address.

Source: npm view viem version dist-tags time; viem@2.56.9 chains/definitions/sepolia.ts; https://docs.ens.domains/web/ensv2-readiness ; https://docs.ens.domains/ensv2/tutorial-app-developers

## Docs mismatch: PermissionedResolver setter signatures

*Confidence: high*

The app-developer tutorial's viem and ethers write examples use setText(bytes32 node, ...) and setAddr(bytes32, address). The deployed 09-15 PermissionedResolverImpl ABI has only DNS-encoded-name setters: setText(bytes name, string, string), setAddress(bytes name, uint256 coinType, bytes addr), setContenthash(bytes, bytes), setABI, setData, setInterface, setName. The Permissioned Resolver docs page (updated 09-17) matches the deployed ABI. For per-account resolvers, encode the name with toHex(packetToBytes(name)) and use setAddress(name, 60n, address).

Source: contracts-v2@sepolia-deployment-2026-09-15 deployments/sepolia/PermissionedResolverImpl.json ABI + src/resolver/PermissionedResolver.sol:164-221; https://docs.ens.domains/ensv2/permissioned-resolver ; https://docs.ens.domains/ensv2/tutorial-app-developers#set-records

## PublicResolverV2 is not for new names

*Confidence: medium*

PublicResolverV2 (0xd7e590...) keeps the familiar bytes32-node v1 setters. But its canModifyName() first requires NAME_WRAPPER.names(node) to be non-empty, then checks the owner through the v2 RootRegistry. So it only authorizes names known to the v1 NameWrapper (migrated or wrapped names). A freshly registered v2 name should use its own PermissionedResolver proxy.

Source: contracts-v2@sepolia-deployment-2026-09-15 contracts/src/resolver/PublicResolverV2.sol lines 174-194

## Onchain subnames in v2

*Confidence: high*

The official pattern: deploy a UserRegistry proxy for your name via VerifiableFactory. Call ETHRegistry.setSubregistry(uint256(keccak256(label)), userRegistry); you already hold ROLE_SET_SUBREGISTRY from registration. Then either call UserRegistry.register(string label, address owner, address subregistry, address resolver, uint256 roleBitmap, uint64 expiry) yourself, or grant a registrar contract ROLE_REGISTRAR (1<<0) | ROLE_RENEW (1<<16) with grantRootRoles. Subnames become ERC1155 tokens in a collection for that name, and token IDs are mutable, so key caches by labelhash.

Source: https://docs.ens.domains/ensv2/tutorial-contract-developers ; deployments/sepolia/UserRegistryImpl.json ABI

## Cheapest onchain option: wildcard subnames via the parent's resolver

*Confidence: medium*

The v2 Universal Resolver uses the closest ancestor's resolver when a name has none of its own ('deepest resolver found wins'). PermissionedResolver implements IExtendedResolver (ENSIP-10) and resolve(bytes name, bytes data), and it keys records by name. So records written on the parent's PermissionedResolver for e.g. lease-42.<team>.eth should resolve without registering the subname or deploying a UserRegistry. There is also a 'default record' fallback for unlinked names. Search summaries of the Tokyo ENS track mention 'resolving subnames straight off a parent's resolver with wildcard resolution'. This is my inference from the code and docs; test it on-chain before relying on it.

Source: https://docs.ens.domains/ensv2/registry-hierarchy#resolution ; https://docs.ens.domains/ensv2/permissioned-resolver#records-and-linking ; contracts-v2 src/resolver/AbstractRecordResolver.sol:54,110

## Primary names (ENSIP-19) on Sepolia v2

*Confidence: high*

At v2 launch, reverse resolution still runs on v1 infrastructure. For addr.reverse, use ReverseRegistrar 0xA0a1AbcDAe1a2a4A2EF8e9113Ff0e02DD81DC0C6 (claimForAddr/setName). For ENSIP-19 default.reverse, use DefaultReverseRegistrar 0x4F382928805ba0e23B30cFB75fC9E848e82DFD47 (setNameForAddr). A contract such as the escrow can get a primary name through ReverseRegistrarAdapter or DefaultReverseRegistrarAdapter, if the caller is the contract itself, its Ownable owner, or passes IContractNamer. The UR forward-verifies primary names and reverts with ReverseAddressMismatch on a mismatch. Multichain L2ReverseRegistrar with signature claims is listed as 'Upcoming'.

Source: https://docs.ens.domains/ensv2/reverse-resolution ; ensjs main src/clients/l1.ts (sepolia ensReverseRegistrar/ensDefaultReverseRegistrar/adapters)

## Hackathon prize guidance

*Confidence: medium*

Search results say the ETHGlobal Tokyo 2026 (Sep 25-27) ENS prize is $6,000 (one third-party prep repo also lists $10,000). The track covers ENSv2 on Sepolia: registry hierarchy and subname registries, Enhanced Access Control roles, Permissioned Resolvers, wildcard resolution, record and namespace aliasing. It asks you to integrate ENSv2 into an existing project, with bonus mention of 'agents as namespaces'. The ETHOnline 2026 'Best use of ENSv2' ($4,500) requirements were: use ENSv2 on Sepolia, make it clear how ENSv2 improves the project (not cosmetic), and a functional demo without hard-coded values. The Tokyo page itself (ethglobal.com) is blocked, so the exact Tokyo wording is unconfirmed.

Source: WebSearch results for https://ethglobal.com/events/tokyo2026/prizes and https://ethglobal.com/events/ethonline2026/prizes/ens ; third-party https://github.com/yolo-company/ethtokyo2026-prepare (README.md, 06-trinity-guardian.md)

## ENS hackathon docs banner

*Confidence: high*

The ENS docs ran a banner 'Hacking at ETHOnline 2026? Read the ENSv2 hackathon docs' linking a preview branch (feature-permres-inode-refact.docs-bao.pages.dev). It was removed on 2026-09-17 when the permissioned-resolver record-linking docs landed on main. The main docs site now includes the ENSv2 pages. Also relevant to builders: https://docs.ens.domains/llms.txt and /llms-full.txt.

Source: ensdomains/docs commit 35d6483 'Remove ETHOnline 2026 banner (#595)'; src/pages/building-with-ai.mdx

## Fallback: NameStone

*Confidence: high*

NameStone is not an option. It shut down on 2026-08-03 and no longer issues API keys. Its README says: 'NameStone is shutting down August 3, 2026, and is no longer issuing new API keys.' Its Sepolia resolver was 0x467893bFE201F8EfEa09BBD53fB69282e6001595.

Source: git clone https://github.com/namestonehq/namestone (README.md line 123, components/ShutdownBanner.js, utils/ServerUtils.js; HEAD 5162a1e 2026-09-05)

## Fallback: Durin

*Confidence: high*

Durin is marked experimental. Its shared L1Resolver 0x8A968aB9eb8C084FBC44c531058Fc9ef945c3D61 authorizes setL2Registry through the ENSv1 registry: ens.owner(node) at 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e, or the NameWrapper owner. A name that exists only in Sepolia v2 would therefore fail with Unauthorized. Durin also requires an L2 registry: factory 0xDddddDdDDD8Aa1f237b4fa0669cb46892346d22d on Base, OP, Arbitrum, Linea, Scroll, Celo, Polygon Amoy and Worldchain Sepolia. It does not fit a project that is Ethereum Sepolia only with a v2 name. The ENS docs subdomains page still recommends Durin for L2 subnames.

Source: https://raw.githubusercontent.com/namestonehq/durin/main/README.md ; https://raw.githubusercontent.com/namestonehq/durin/main/src/L1Resolver.sol (lines 57, 123-140; HEAD f19cd3e 2026-07-18); https://docs.ens.domains/web/subdomains

## Fallback: Namespace

*Confidence: medium*

Namespace's @thenamespace/offchain-manager 1.0.13 supports mode 'sepolia'. API keys come from https://dev.namespace.ninja, and the SDK talks to offchain-manager.namespace.ninja or the staging host. @thenamespace/mint-manager 2.0.0 (2026-09-21) has isTestnet for Sepolia listings. Its README notes that v1 registry owner() calls report v2-migrated names as unowned, so it treats the Namespace API as the source of truth. I could not find Namespace's Sepolia offchain resolver address (docs.namespace.ninja blocked), and I don't know whether the dev portal accepts a parent name that exists only in v2.

Source: npm pack @thenamespace/offchain-manager@1.0.13 README/dist; npm pack @thenamespace/mint-manager@2.0.0 README ('ENS v2' section); https://github.com/thenamespace/skills

## Fallback: self-hosted CCIP-read

*Confidence: medium*

The ENS docs list gskril/ens-offchain-registrar as an open-source offchain (CCIP-read / ENSIP-10) option. It works for any name whose resolver you control. On v2, call ETHRegistry.setResolver(tokenId, resolver), which needs ROLE_SET_RESOLVER; you get that role at registration. The v2 UR drives CCIP-read. This avoids depending on third-party subname services, but it costs a gateway deploy (e.g. a Cloudflare Worker).

Source: https://docs.ens.domains/web/subdomains ; https://docs.ens.domains/web/ensv2-readiness (write-path table: setResolver(tokenId,...) on the registry)

## Third-party kits have stale addresses

*Confidence: high*

Community kits pin addresses from before the redeploy. For example, jefflau/enspack (last commit 2026-09-15) uses UR 0x4a1817d13e9cf196f471725176355c1234b63c70, VerifiableFactory 0x10dc6333..., UserRegistryImpl 0x624a25d6..., PermissionedResolverImpl 0x9eae5c27... and ETHRegistrar 0xa88553f4..., all from the 07-30 deployment. Take addresses only from contracts-v2 tag sepolia-deployment-2026-09-15 or from the docs.

Source: git clone https://github.com/jefflau/enspack (packages/core/src/ens/v2/config.ts); ensjs commit 101c7fe diff (old -> new addresses)

## Snippet: Sepolia ENSv2 flow with viem (addresses from the 2026-09-15 deployment)

Source: Synthesized from docs.ens.domains/ensv2/eth-registrar, /ensv2/verifiable-factory, /ensv2/tutorial-app-developers and contracts-v2@sepolia-deployment-2026-09-15 deployment ABIs

```ts
import { createPublicClient, createWalletClient, http, parseAbi, keccak256, toHex, encodeAbiParameters, encodeFunctionData, stringToHex, erc20Abi } from 'viem'
import { sepolia } from 'viem/chains'
import { packetToBytes, normalize } from 'viem/ens'

const A = {
  ethRegistrar: '0xAbe76F6C8DFcEd81AA5A2bB8034202A7136b94ca',
  ethRegistry: '0x657eA849311d3D5823348ddEd7C2AaAFb3EDE09E',
  verifiableFactory: '0x9e726Eb570beb6BCEb495AB8cdA7df517d4e841C',
  permissionedResolverImpl: '0x14F09Fd05d4585759e54844DC9B00147131Cf243',
  userRegistryImpl: '0xA80338aAA8D23831cEa25E858D1774534aBb0263',
  mockUsdc: '0x16f95D91DBa7dA3Aca778Ec053dF0FF6C6A8aA8e', // mint() is open to anyone; nuke() lets anyone burn any balance -> use for ENS fees only
  circleUsdc: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
} as const

// 1) Deploy your own resolver proxy: salt = keccak256(abi.encode(keccak256('OwnedResolver'), owner, 0))
//    VerifiableFactory.deployProxy(impl, salt, initialize([(owner, ALL_ROLES)], []))
// 2) MockUSDC.mint(me, 100e6); approve(ethRegistrar, price)
// 3) ETHRegistrar.commit(makeCommitment(label, owner, secret, 0x0, resolverProxy, 31536000n, 0x00..00)); wait >= 60s
// 4) ETHRegistrar.register(label, owner, secret, 0x0, resolverProxy, 31536000n, paymentToken, 0x00..00)
// 5) Records: PermissionedResolver setters take the DNS-encoded NAME, not a namehash:
const dnsName = toHex(packetToBytes(normalize('rentouts-demo.eth')))
// setText(bytes name, string key, string value); setAddress(bytes name, uint256 coinType, bytes addr)
// Reads: plain viem on `sepolia` (UR 0xeEeE...EeEe built in): client.getEnsAddress / getEnsText / getEnsName
```

## Snippet: ENS MockUSDC: open mint and open nuke (why it must not hold escrow funds)

Source: ensdomains/contracts-v2@sepolia-deployment-2026-09-15 contracts/test/mocks/MockERC20.sol:26-32 (deployed as MockUSDC 0x16f95d91dba7da3aca778ec053df0ff6c6a8aa8e)

```solidity
function mint(address to, uint256 amount) external { _mint(to, amount); }
function nuke(address owner) external { _burn(owner, balanceOf(owner)); }
```

## Snippet: Durin L1Resolver checks v1 ownership (incompatible with names that exist only in v2)

Source: https://raw.githubusercontent.com/namestonehq/durin/main/src/L1Resolver.sol lines 123-140

```solidity
function setL2Registry(bytes32 node, uint64 targetChainId, address targetRegistryAddress) external {
    address owner = ens.owner(node); // ENSv1 registry 0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e
    if (owner == address(nameWrapper)) { owner = nameWrapper.ownerOf(uint256(node)); }
    if (owner != msg.sender) { revert Unauthorized(); }
    ...
```

## Open questions

- I could not check on-chain state because Sepolia RPC is blocked here. Someone with a working RPC should confirm the v1 freeze: BaseRegistrar(0x57f1887a...).controllers(0xfb3cE5D0...) should be false and owner() should be ETHRenewerV1 0xd06e726e.... They should also check that StandardRentPriceOracle.isPaymentToken(Circle USDC 0x1c7D4B19...) is still true.
- Will ENS redeploy or reset Sepolia v2 between Sep 25 and 27? Nothing announces a redeploy, but past tags came every 4-6 weeks and the last one was 09-15. The team should script re-registration and keep only the UR proxy address fixed.
- I don't have the exact Tokyo 2026 ENS prize wording or amount ($6,000 per search, $10,000 in one third-party note), because ethglobal.com is blocked. Someone should read https://ethglobal.com/events/tokyo2026/prizes in a browser.
- Does app.ens.dev let you register a brand-new v2 name today, or only upgrade v1 names? It was blocked for WebFetch.
- Namespace: what is the Sepolia offchain resolver address, and will dev.namespace.ninja issue a key for a parent name that exists only in v2? docs.namespace.ninja was blocked.
- The wildcard approach (records for unregistered subnames written on the parent's PermissionedResolver and served through the UR's closest-ancestor lookup) is inferred from code and docs. It needs a live Sepolia test before the team relies on it.
