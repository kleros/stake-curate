
require("dotenv").config();

import "@nomiclabs/hardhat-etherscan"
import "@nomiclabs/hardhat-waffle"
import "hardhat-gas-reporter"
import "solidity-coverage"
import "hardhat-contract-sizer"

import { HardhatUserConfig } from "hardhat/types/config";

/**
 * @type import('hardhat/config').HardhatUserConfig
 */

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.14",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  networks: {
    kovan: {
      url: process.env.KOVAN_URL || "",
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
}

export default config