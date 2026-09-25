import { parseAbi } from 'viem'

/** RentoutsSubnames (ens/src/RentoutsSubnames.sol): the subset the app calls, plus every custom error. */
export const rentoutsSubnamesAbi = parseAbi([
  'function register(string label, address holder) returns (uint256 tokenId)',
  'function setProfileText(string label, string key, string value)',
  'function labelOf(address holder) view returns (string)',
  'function nameOf(address holder) view returns (string)',
  'function holderOf(uint256 labelId) view returns (address)',
  'function retired(uint256 labelId) view returns (bool)',
  'function dnsName(string label) view returns (bytes)',
  'function parentName() view returns (string)',

  'event Claimed(string label, address indexed holder, uint256 tokenId)',

  'error NotAdmin()',
  'error NotIssuer()',
  'error NotAuthorized()',
  'error NotHolder(string label)',
  'error InvalidLabel(string label)',
  'error AlreadyHasName(address holder)',
  'error LabelRetired(string label)',
  'error LabelTaken(string label)',
  'error UnknownLabel(string label)',
  'error NotCredentialKey(string key)',
  'error ProfileKeyNotAllowed(string key)',
  'error ZeroAddress()',
])
