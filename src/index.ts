#!/usr/bin/env node

import { spawn, execSync } from 'child_process';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import path from 'path';
import { render } from 'ink';
import React from 'react';
import { Command } from 'commander';
import { App } from './ui/App.js';
import { getProviders, isDbAvailable } from './db.js';
import { loadHistory, saveToHistory, sortByHistory } from './history.js';
import { createProviderSettings, clearAllCcscSettings } from './settings.js';
import type { Provider } from './types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(path.join(__dirname, '..', 'package.json'), 'utf-8'));

const program = new Command();

program
  .name('ccsc')
  .description('Cross-platform CLI for CC Switch provider selection')
  .version(pkg.version)
  .option('--provider <name>', 'Specify provider by name (skips interactive selection)')
  .option('--clear', 'Clear all CCSC-generated settings files')
  .option('--cli <name>', 'Specify CLI tool to use (overrides CC_CLI_PATH env)')
  .allowUnknownOption()
  .allowExcessArguments()
  .passThroughOptions()
  .action(async (options) => {
    try {
      // Handle --clear flag
      if (options.clear) {
        const removed = await clearAllCcscSettings();
        if (removed > 0) {
          console.log(`✓ Cleared ${removed} CCSC settings file(s)`);
        } else {
          console.log('No CCSC settings files found');
        }
        process.exit(0);
      }

      // Extract --provider option
      const providerOverride = options.provider;
      // Extract --cli option and remaining args
      const cliOverride = options.cli;
      const rawArgs = process.argv.slice(2).filter(
        (arg, index, arr) => {
          // 跳過 --clear
          if (arg === '--clear') return false;
          // 跳過 --cli 及其值
          if (arg.startsWith('--cli')) return false;
          if (arg === cliOverride) return false;
          // 跳過 --provider 及其值
          if (arg.startsWith('--provider')) return false;
          if (arg === providerOverride) return false;
          return true;
        }
      );
      await main(rawArgs, cliOverride, providerOverride);
    } catch (error) {
      console.error(
        'Error:',
        error instanceof Error ? error.message : String(error)
      );
      process.exit(1);
    }
  });

program.parse();

async function main(claudeArgs: string[], cliOverride?: string, providerName?: string): Promise<void> {
  if (!isDbAvailable()) {
    console.error('CC Switch database not found.');
    console.error(
      'Please ensure CC Switch is installed and has been run at least once.'
    );
    process.exit(1);
  }

  const providers = getProviders();

  if (providers.length === 0) {
    console.error('No Claude providers found in CC Switch.');
    console.error('Please add providers in CC Switch first.');
    process.exit(1);
  }

  // If provider name specified, find it directly
  let selectedProvider: Provider;
  if (providerName) {
    const matched = providers.find(
      (p) => p.name.toLowerCase() === providerName.toLowerCase()
    );
    if (!matched) {
      console.error(`Provider "${providerName}" not found.`);
      console.error('Available providers:');
      providers.forEach((p) => console.error(`  - ${p.name}`));
      process.exit(1);
    }
    selectedProvider = matched;
    console.log(`✓ Using provider: ${selectedProvider.name}`);
  } else {
    // Sort by history
    const history = await loadHistory();
    const sortedProviders = sortByHistory(providers, history);

    // Render Ink UI and wait for selection
    selectedProvider = await new Promise<Provider>((resolve, reject) => {
      const { unmount } = render(
        React.createElement(App, {
          providers: sortedProviders,
          onSelect: (provider: Provider) => {
            unmount();
            resolve(provider);
          },
        })
      );
    });
  }

  // Save to history
  await saveToHistory(selectedProvider.name);

  // Create provider-specific settings file with merged env
  const settingsPath = await createProviderSettings(
    selectedProvider.name,
    selectedProvider.envVars,
    selectedProvider.settingsConfig
  );

  // Build claude args with --settings parameter
  const finalArgs = [`--settings=${settingsPath}`, ...claudeArgs];

  // Spawn claude process
  console.log(`🚀 Starting Claude with provider: ${selectedProvider.name}`);

  // Priority: --cli option > CC_CLI_PATH env var > 'claude' default
  const claudeBin = cliOverride || process.env.CC_CLI_PATH || 'claude';

  // Spawn through the user's interactive shell (`$SHELL -i -c`) so that:
  // 1. PATH and rc-file tooling load as if the user typed the command themselves
  // 2. Child processes (MCP servers that need `node`/`npx`) find their deps
  //
  // Problem: version managers (volta/nvm/asdf) can inject shim paths that shadow
  // the user's intended `claude` binary. We solve this by resolving `claude` to
  // its canonical path via the user's LOGIN shell (which reflects their intended
  // PATH without version-manager injection from the current process tree), then
  // spawning that absolute path inside an interactive shell (so children still
  // get the full environment).
  const userShell = process.env.SHELL;

  // Resolve claude to absolute path: start a clean login shell (env -i strips
  // inherited PATH pollution from version managers) and let it rebuild PATH
  // from rc files, then `which` the binary. This finds the claude the user
  // actually intends to run, regardless of what ccsc's own process tree injected.
  let resolvedBin = claudeBin;
  if (userShell && !claudeBin.includes('/')) {
    try {
      const result = execSync(
        `env -i HOME="${process.env.HOME}" SHELL="${userShell}" TERM="${process.env.TERM || 'xterm-256color'}" ${userShell} -l -i -c 'which ${claudeBin}'`,
        { encoding: 'utf-8', timeout: 5000, stdio: ['pipe', 'pipe', 'pipe'] }
      ).trim();
      if (result && !result.includes('not found')) {
        resolvedBin = result;
      }
    } catch {
      // Fall through with original name
    }
  }

  const child = userShell
    ? spawn(
        userShell,
        ['-i', '-c', 'exec "$@"', 'ccsc', resolvedBin, ...finalArgs],
        { stdio: 'inherit' }
      )
    : spawn(resolvedBin, finalArgs, {
        stdio: 'inherit',
        shell: process.platform === 'win32',
      });

  child.on('error', (err) => {
    console.error(`Failed to start ${claudeBin}:`, err.message);
    console.error('Please ensure Claude CLI is installed and in your PATH.');
    console.error('You can set CC_CLI_PATH environment variable or use --cli option to specify a custom CLI.');
    process.exit(1);
  });

  child.on('exit', (code) => {
    process.exit(code || 0);
  });
}
