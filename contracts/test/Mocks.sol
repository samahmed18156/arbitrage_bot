// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n) { name = n; }

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Minimal Uniswap-V2 pair (0.30% fee, constant product).
contract MockPair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) { return (reserve0, reserve1, 0); }

    function sync() external {
        reserve0 = uint112(MockERC20(token0).balanceOf(address(this)));
        reserve1 = uint112(MockERC20(token1).balanceOf(address(this)));
    }

    function swap(uint256 a0, uint256 a1, address to, bytes calldata) external {
        require(a0 > 0 || a1 > 0, "INSUFFICIENT_OUTPUT");
        if (a0 > 0) MockERC20(token0).transfer(to, a0);
        if (a1 > 0) MockERC20(token1).transfer(to, a1);
        uint256 b0 = MockERC20(token0).balanceOf(address(this));
        uint256 b1 = MockERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > reserve0 - a0 ? b0 - (reserve0 - a0) : 0;
        uint256 in1 = b1 > reserve1 - a1 ? b1 - (reserve1 - a1) : 0;
        require(in0 > 0 || in1 > 0, "INSUFFICIENT_INPUT");
        uint256 adj0 = b0 * 1000 - in0 * 3;
        uint256 adj1 = b1 * 1000 - in1 * 3;
        require(adj0 * adj1 >= uint256(reserve0) * reserve1 * 1e6, "K");
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
    }
}

interface IRecipient {
    function receiveFlashLoan(MockERC20[] memory, uint256[] memory, uint256[] memory, bytes memory) external;
}

/// Balancer-style vault: lends, calls back, requires repayment.
contract MockVault {
    uint256 public feeBps;
    constructor(uint256 f) { feeBps = f; }

    function flashLoan(address recipient, MockERC20[] memory tokens, uint256[] memory amounts, bytes memory data) external {
        uint256 pre = tokens[0].balanceOf(address(this));
        uint256[] memory fees = new uint256[](1);
        fees[0] = amounts[0] * feeBps / 10_000;
        tokens[0].transfer(recipient, amounts[0]);
        IRecipient(recipient).receiveFlashLoan(tokens, amounts, fees, data);
        require(tokens[0].balanceOf(address(this)) >= pre + fees[0], "NOT_REPAID");
    }
}
