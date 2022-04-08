import "./../Cint32.sol";

contract Cint32Test{
    using Cint32 for uint256;
    using Cint32 for uint32;
    uint8 public digits;
    constructor(){
    }

    function compress(uint256 _val) public pure returns (uint32){
        return _val.compress();
    }

    function decompress(uint32 _val) public pure returns (uint256){
        return _val.decompress();
    }
}