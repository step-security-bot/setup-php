import {IncomingMessage, OutgoingHttpHeaders} from 'http';
import * as fs from 'fs';
import * as https from 'https';
import * as path from 'path';
import * as url from 'url';
import * as core from '@actions/core';

/**
 * Function to read environment variable and return a string value.
 *
 * @param property
 */
export async function readEnv(property: string): Promise<string> {
  const property_lc: string = property.toLowerCase();
  const property_uc: string = property.toUpperCase();
  return (
    process.env[property] ||
    process.env[property_lc] ||
    process.env[property_uc] ||
    process.env[property_lc.replace('_', '-')] ||
    process.env[property_uc.replace('_', '-')] ||
    ''
  );
}

/**
 * Function to get inputs from both with and env annotations.
 *
 * @param name
 * @param mandatory
 */
export async function getInput(
  name: string,
  mandatory: boolean
): Promise<string> {
  const input = core.getInput(name);
  const env_input = await readEnv(name);
  switch (true) {
    case input != '':
      return input;
    case input == '' && env_input != '':
      return env_input;
    case input == '' && env_input == '' && mandatory:
      throw new Error(`Input required and not supplied: ${name}`);
    default:
      return '';
  }
}

/**
 * Function to fetch an URL
 *
 * @param input_url
 * @param auth_token
 */
export async function fetch(
  input_url: string,
  auth_token?: string
): Promise<Record<string, string>> {
  const fetch_promise: Promise<Record<string, string>> = new Promise(
    resolve => {
      const url_object: url.UrlObject = new url.URL(input_url);
      const headers: OutgoingHttpHeaders = {
        'User-Agent': `Mozilla/5.0 (${process.platform} ${process.arch}) setup-php`
      };
      if (auth_token) {
        headers.authorization = 'Bearer ' + auth_token;
      }
      const options: https.RequestOptions = {
        hostname: url_object.hostname,
        path: url_object.pathname,
        headers: headers
      };
      const req = https.get(options, (res: IncomingMessage) => {
        if (res.statusCode != 200) {
          resolve({error: `${res.statusCode}: ${res.statusMessage}`});
        } else {
          let body = '';
          res.setEncoding('utf8');
          res.on('data', chunk => (body += chunk));
          res.on('end', () => resolve({data: `${body}`}));
        }
      });
      req.end();
    }
  );
  return await fetch_promise;
}

/** Function to get manifest URL
 *
 */
export async function getManifestURL(): Promise<string> {
  return 'https://raw.githubusercontent.com/shivammathur/setup-php/develop/src/configs/php-versions.json';
}

/**
 * Function to parse PHP version.
 *
 * @param version
 */
export async function parseVersion(version: string): Promise<string> {
  const manifest = await getManifestURL();
  switch (true) {
    case /^(latest|nightly|\d+\.x)$/.test(version):
      return JSON.parse((await fetch(manifest))['data'])[version];
    default:
      switch (true) {
        case version.length > 1:
          return version.slice(0, 3);
        default:
          return version + '.0';
      }
  }
}

/**
 * Async foreach loop
 *
 * @author https://github.com/Atinux
 * @param array
 * @param callback
 */
export async function asyncForEach(
  array: Array<string>,
  callback: (
    element: string,
    index: number,
    array: Array<string>
  ) => Promise<void>
): Promise<void> {
  for (let index = 0; index < array.length; index++) {
    await callback(array[index], index, array);
  }
}

/**
 * Get color index
 *
 * @param type
 */
export async function color(type: string): Promise<string> {
  switch (type) {
    case 'error':
      return '31';
    default:
    case 'success':
      return '32';
    case 'warning':
      return '33';
  }
}

/**
 * Log to console
 *
 * @param message
 * @param os_version
 * @param log_type
 */
export async function log(
  message: string,
  os_version: string,
  log_type: string
): Promise<string> {
  switch (os_version) {
    case 'win32':
      return (
        'printf "\\033[' +
        (await color(log_type)) +
        ';1m' +
        message +
        ' \\033[0m"'
      );

    case 'linux':
    case 'darwin':
    default:
      return (
        'echo "\\033[' + (await color(log_type)) + ';1m' + message + '\\033[0m"'
      );
  }
}

/**
 * Function to log a step
 *
 * @param message
 * @param os_version
 */
export async function stepLog(
  message: string,
  os_version: string
): Promise<string> {
  switch (os_version) {
    case 'win32':
      return 'Step-Log "' + message + '"';
    case 'linux':
    case 'darwin':
      return 'step_log "' + message + '"';
    default:
      return await log(
        'Platform ' + os_version + ' is not supported',
        os_version,
        'error'
      );
  }
}

/**
 * Function to log a result
 * @param mark
 * @param subject
 * @param message
 * @param os_version
 */
export async function addLog(
  mark: string,
  subject: string,
  message: string,
  os_version: string
): Promise<string> {
  switch (os_version) {
    case 'win32':
      return 'Add-Log "' + mark + '" "' + subject + '" "' + message + '"';
    case 'linux':
    case 'darwin':
      return 'add_log "' + mark + '" "' + subject + '" "' + message + '"';
    default:
      return await log(
        'Platform ' + os_version + ' is not supported',
        os_version,
        'error'
      );
  }
}

/**
 * Read the scripts
 *
 * @param filename
 * @param directory
 */
export async function readFile(
  filename: string,
  directory: string
): Promise<string> {
  return fs.readFileSync(
    path.join(__dirname, '../' + directory, filename),
    'utf8'
  );
}

/**
 * Write final script which runs
 *
 * @param filename
 * @param script
 */
export async function writeScript(
  filename: string,
  script: string
): Promise<string> {
  const runner_dir: string = await getInput('RUNNER_TOOL_CACHE', false);
  const script_path: string = path.join(runner_dir, filename);
  fs.writeFileSync(script_path, script, {mode: 0o755});
  return script_path;
}

/**
 * Function to break extension csv into an array
 *
 * @param extension_csv
 */
export async function extensionArray(
  extension_csv: string
): Promise<Array<string>> {
  switch (extension_csv) {
    case '':
    case ' ':
      return [];
    default:
      return [
        extension_csv.match(/(^|,\s?)none(\s?,|$)/) ? 'none' : '',
        ...extension_csv
          .split(',')

          .map(function (extension: string) {
            if (/.+-.+\/.+@.+/.test(extension)) {
              return extension;
            }
            return extension
              .trim()
              .toLowerCase()
              .replace(/^(:)?(php[-_]|none|zend )/, '$1');
          })
      ].filter(Boolean);
  }
}

/**
 * Function to break csv into an array
 *
 * @param values_csv
 * @constructor
 */
export async function CSVArray(values_csv: string): Promise<Array<string>> {
  switch (values_csv) {
    case '':
    case ' ':
      return [];
    default:
      return values_csv
        .split(/,(?=(?:(?:[^"']*["']){2})*[^"']*$)/)
        .map(function (value) {
          return value
            .trim()
            .replace(/^["']|["']$|(?<==)["']/g, '')
            .replace(/=(((?!E_).)*[?{}|&~![()^]+((?!E_).)+)/, "='$1'");
        })
        .filter(Boolean);
  }
}

/**
 * Function to get prefix required to load an extension.
 *
 * @param extension
 */
export async function getExtensionPrefix(extension: string): Promise<string> {
  switch (true) {
    default:
      return 'extension';
    case /xdebug([2-3])?$|opcache|ioncube|eaccelerator/.test(extension):
      return 'zend_extension';
  }
}

/**
 * Function to get the suffix to suppress console output
 *
 * @param os_version
 */
export async function suppressOutput(os_version: string): Promise<string> {
  switch (os_version) {
    case 'win32':
      return ' ';
    case 'linux':
    case 'darwin':
      return ' ';
    default:
      return await log(
        'Platform ' + os_version + ' is not supported',
        os_version,
        'error'
      );
  }
}

/**
 * Function to get script to log unsupported extensions.
 *
 * @param extension
 * @param version
 * @param os_version
 */
export async function getUnsupportedLog(
  extension: string,
  version: string,
  os_version: string
): Promise<string> {
  return (
    '\n' +
    (await addLog(
      '$cross',
      extension,
      [extension, 'is not supported on PHP', version].join(' '),
      os_version
    )) +
    '\n'
  );
}

/**
 * Function to get command to setup tools
 *
 * @param os_version
 * @param suffix
 */
export async function getCommand(
  os_version: string,
  suffix: string
): Promise<string> {
  switch (os_version) {
    case 'linux':
    case 'darwin':
      return 'add_' + suffix + ' ';
    case 'win32':
      return 'Add-' + suffix.charAt(0).toUpperCase() + suffix.slice(1) + ' ';
    default:
      return await log(
        'Platform ' + os_version + ' is not supported',
        os_version,
        'error'
      );
  }
}

/**
 * Function to join strings with space
 *
 * @param str
 */
export async function joins(...str: string[]): Promise<string> {
  return [...str].join(' ');
}

/**
 * Function to get script extensions
 *
 * @param os_version
 */
export async function scriptExtension(os_version: string): Promise<string> {
  switch (os_version) {
    case 'win32':
      return '.ps1';
    case 'linux':
    case 'darwin':
      return '.sh';
    default:
      return await log(
        'Platform ' + os_version + ' is not supported',
        os_version,
        'error'
      );
  }
}

/**
 * Function to get script tool
 *
 * @param os_version
 */
export async function scriptTool(os_version: string): Promise<string> {
  switch (os_version) {
    case 'win32':
      return 'pwsh';
    case 'linux':
    case 'darwin':
      return 'bash';
    default:
      return await log(
        'Platform ' + os_version + ' is not supported',
        os_version,
        'error'
      );
  }
}

/**
 * Function to get script to add tools with custom support.
 *
 * @param pkg
 * @param type
 * @param version
 * @param os_version
 */
export async function customPackage(
  pkg: string,
  type: string,
  version: string,
  os_version: string
): Promise<string> {
  const pkg_name: string = pkg.replace(/\d+|(pdo|pecl)[_-]/, '');
  const script_extension: string = await scriptExtension(os_version);
  const script: string = path.join(
    __dirname,
    '../src/scripts/' + type + '/' + pkg_name + script_extension
  );
  const command: string = await getCommand(os_version, pkg_name);
  return '\n. ' + script + '\n' + command + version;
}

/**
 * Function to extension input for installation from source.
 *
 * @param extension
 * @param prefix
 */
export async function parseExtensionSource(
  extension: string,
  prefix: string
): Promise<string> {
  // Groups: extension, domain url, org, repo, release
  const regex = /(\w+)-(.+:\/\/.+(?:[.:].+)+\/)?([\w.-]+)\/([\w.-]+)@(.+)/;
  const matches = regex.exec(extension) as RegExpExecArray;
  matches[2] = matches[2] ? matches[2].slice(0, -1) : 'https://github.com';
  return await joins(
    '\nadd_extension_from_source',
    ...matches.splice(1, matches.length),
    prefix
  );
}
