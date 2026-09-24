// 拉取离线 xterm.js 资产到 assets/xterm/
//
// 为什么不用 CDN：终端必须离线可用（与 assets/md_viewer 的做法一致），
// 且 WebView 的 loadData 页面是 opaque origin，外链资源会被 CSP/网络环境挡住。
//
// 用法：node tool/fetch_xterm_assets.mjs
// 依赖：Node 18+（只用内置 fetch/zlib/crypto，不依赖 npm install）
//
// 上游来源与版本固定（见文件末尾 VERSIONS），走 npmmirror 镜像加速。
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { gunzipSync } from 'node:zlib';

const REGISTRY = 'https://registry.npmmirror.com';
const OUT_DIR = 'assets/xterm';

/** 固定版本：升级时改这里，并重新跑一次脚本核对哈希。 */
const VERSIONS = {
  '@xterm/xterm': '6.0.0',
  '@xterm/addon-fit': '0.11.0',
  '@xterm/addon-webgl': '0.19.0',
  '@xterm/addon-unicode11': '0.9.0',
  '@xterm/addon-web-links': '0.12.0',
};

/** 每个包要落地的成员文件：tar 内路径 -> 输出文件名 */
const WANTED = {
  '@xterm/xterm': {
    'package/lib/xterm.js': 'xterm.js',
    'package/css/xterm.css': 'xterm.css',
    'package/LICENSE': 'LICENSE.xterm',
  },
  '@xterm/addon-fit': {
    'package/lib/addon-fit.js': 'addon-fit.js',
    'package/LICENSE': 'LICENSE.addon-fit',
  },
  '@xterm/addon-webgl': {
    'package/lib/addon-webgl.js': 'addon-webgl.js',
    'package/LICENSE': 'LICENSE.addon-webgl',
  },
  '@xterm/addon-unicode11': {
    'package/lib/addon-unicode11.js': 'addon-unicode11.js',
    'package/LICENSE': 'LICENSE.addon-unicode11',
  },
  '@xterm/addon-web-links': {
    'package/lib/addon-web-links.js': 'addon-web-links.js',
    'package/LICENSE': 'LICENSE.addon-web-links',
  },
};

/**
 * 极简 tar 解包：只取需要的成员。
 * npm tarball 是 gzip + ustar/PAX，路径都很短，PAX 扩展头（type 'x'）跳过即可。
 */
function extractMembers(tarGzBuffer, wantedPaths) {
  const tar = gunzipSync(tarGzBuffer);
  const found = new Map();
  let offset = 0;
  while (offset + 512 <= tar.length) {
    const name = tar
      .toString('utf8', offset, offset + 100)
      .replace(/\0.*$/s, '');
    if (name === '') break; // 连续的零块 = 归档结束
    const sizeText = tar
      .toString('utf8', offset + 124, offset + 136)
      .replace(/\0.*$/s, '')
      .trim();
    const size = parseInt(sizeText, 8) || 0;
    const typeFlag = String.fromCharCode(tar[offset + 156]);
    const dataStart = offset + 512;
    if (wantedPaths.includes(name) && (typeFlag === '0' || typeFlag === '\0')) {
      found.set(name, tar.subarray(dataStart, dataStart + size));
    }
    offset = dataStart + Math.ceil(size / 512) * 512;
  }
  return found;
}

async function fetchTarball(pkg, version) {
  const encoded = pkg.replace('/', '%2f');
  const url = `${REGISTRY}/${encoded}/-/${pkg.split('/').pop()}-${version}.tgz`;
  const res = await fetch(url, { signal: AbortSignal.timeout(60000) });
  if (!res.ok) {
    throw new Error(`下载失败 ${res.status} ${url}`);
  }
  return Buffer.from(await res.arrayBuffer());
}

const rows = [];
for (const [pkg, version] of Object.entries(VERSIONS)) {
  process.stdout.write(`下载 ${pkg}@${version} ... `);
  const tarball = await fetchTarball(pkg, version);
  const members = extractMembers(tarball, Object.keys(WANTED[pkg]));
  for (const [tarPath, outName] of Object.entries(WANTED[pkg])) {
    const data = members.get(tarPath);
    if (!data) {
      throw new Error(`${pkg}@${version} 缺少成员 ${tarPath}`);
    }
    const target = join(OUT_DIR, outName);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, data);
    rows.push({
      file: `${OUT_DIR}/${outName}`,
      bytes: data.length,
      sha256: createHash('sha256').update(data).digest('hex').slice(0, 16),
      source: `${pkg}@${version}:${tarPath}`,
    });
  }
  console.log('ok');
}

console.log('\n落地文件：');
for (const r of rows) {
  console.log(
    `  ${r.file.padEnd(34)} ${String(r.bytes).padStart(8)} B  sha256:${r.sha256}  <- ${r.source}`,
  );
}
console.log(
  '\n注意：xterm.js 与各 addon 均为 MIT 许可，LICENSE.* 已随资产一并落地。',
);
