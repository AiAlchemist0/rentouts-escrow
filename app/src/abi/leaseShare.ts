import { parseAbi } from 'viem'

/** LeaseShare1155 (branch feat/curvegrid-rwa, src/LeaseShare1155.sol) + the OZ v5 ERC-1155 errors it can raise. */
export const leaseShareAbi = parseAbi([
  'function balanceOf(address account, uint256 id) view returns (uint256)',
  'function balanceOfBatch(address[] accounts, uint256[] ids) view returns (uint256[])',
  'function totalSupply(uint256 id) view returns (uint256)',
  'function allowlisted(address account) view returns (bool)',
  'function owner() view returns (address)',
  'function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes data)',

  'error NotAllowlisted(address account)',
  'error NotMinter(address caller)',
  'error ERC1155InsufficientBalance(address sender, uint256 balance, uint256 needed, uint256 tokenId)',
  'error ERC1155InvalidReceiver(address receiver)',
  'error ERC1155MissingApprovalForAll(address operator, address owner)',
])
