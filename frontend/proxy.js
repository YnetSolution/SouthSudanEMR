const http = require('http');
const https = require('https');
const zlib = require('zlib');

const PORT = 4873;
const TOKEN = 'rdt-AYA2VhmQ6oI-ze6HiZzOHIdA7NdvqxAm9SaKEeQh0xI';

const server = http.createServer((req, res) => {
  console.log(`[Proxy] ${req.method} ${req.url}`);

  // Handle tarball request
  const tarballMatch = req.url.match(/^\/tarball\/([^\/]+)\/([^\/]+)$/);
  if (tarballMatch) {
    const [, pkg, version] = tarballMatch;
    const realTarballUrl = `https://repo.repsy.io/ynetsolutions/npm/@ssemrapp/${pkg}/-/${pkg}-${version}.tgz`;
    console.log(`[Proxy] Fetching real tarball: ${realTarballUrl}`);
    
    const headers = { ...req.headers };
    delete headers.host;
    if (!headers.authorization) {
      headers.authorization = `Bearer ${TOKEN}`;
    }
    const cleanHeaders = {
      'user-agent': headers['user-agent'] || 'node-fetch',
      'accept': headers['accept'] || '*/*',
      'accept-encoding': headers['accept-encoding'] || 'gzip,deflate',
      'authorization': headers['authorization']
    };
    console.log(`[Proxy] Outgoing clean headers:`, cleanHeaders);
    
    const targetReq = https.get(realTarballUrl, { headers: cleanHeaders }, (targetRes) => {
      console.log(`[Proxy] Target response status: ${targetRes.statusCode}`);
      if (targetRes.statusCode !== 200) {
        console.log(`[Proxy] Target response headers:`, targetRes.headers);
        let errorBody = [];
        targetRes.on('data', (chunk) => errorBody.push(chunk));
        targetRes.on('end', () => {
          console.log(`[Proxy] Target error body:`, Buffer.concat(errorBody).toString('utf8'));
        });
      }
      res.writeHead(targetRes.statusCode, targetRes.headers);
      targetRes.pipe(res);
    });
    targetReq.on('error', (err) => {
      console.error('[Proxy] Error fetching tarball:', err);
      res.writeHead(500);
      res.end('Error fetching tarball');
    });
    return;
  }

  // Forward other requests (metadata, etc.) to repo.repsy.io
  const targetUrl = `https://repo.repsy.io${req.url}`;
  const headers = { ...req.headers };
  delete headers.host;
  if (!headers.authorization) {
    headers.authorization = `Bearer ${TOKEN}`;
  }
  // The metadata is rewritten below, so it has to arrive as plain JSON. npm and the openmrs CLI
  // ask for gzip; passing that on made Repsy compress the JSON, the rewrite failed, and the
  // tarball links kept pointing at Repsy, which then refused the unauthenticated download.
  headers['accept-encoding'] = 'identity';
  
  const targetReq = https.get(targetUrl, { headers }, (targetRes) => {
    let body = [];
    targetRes.on('data', (chunk) => body.push(chunk));
    targetRes.on('end', () => {
      let data = Buffer.concat(body);

      // Decompress anyway if the registry ignored the request for an uncompressed response.
      const encoding = (targetRes.headers['content-encoding'] || '').toLowerCase();
      try {
        if (encoding === 'gzip') data = zlib.gunzipSync(data);
        else if (encoding === 'deflate') data = zlib.inflateSync(data);
        else if (encoding === 'br') data = zlib.brotliDecompressSync(data);
        if (encoding) {
          delete targetRes.headers['content-encoding'];
          targetRes.headers['content-length'] = data.length;
        }
      } catch (e) {
        console.error(`[Proxy] Could not decompress ${encoding} response:`, e);
      }
      
      if (targetRes.statusCode === 200 && (req.url.includes('@ssemrapp') || req.url.includes('%2f') || req.url.includes('%2F'))) {
        try {
          const jsonStr = data.toString('utf8');
          const json = JSON.parse(jsonStr);
          
          // Rewrite tarball URLs in metadata JSON
          if (json.versions) {
            for (const version in json.versions) {
              const v = json.versions[version];
              if (v.dist && v.dist.tarball) {
                // pkg name without scope
                const pkgName = json.name.split('/').pop();
                v.dist.tarball = `http://127.0.0.1:${PORT}/tarball/${pkgName}/${version}`;
                console.log(`[Proxy] Rewrote version ${version} tarball URL to ${v.dist.tarball}`);
              }
            }
          }
          data = Buffer.from(JSON.stringify(json), 'utf8');
          targetRes.headers['content-length'] = data.length;
        } catch (e) {
          console.error('[Proxy] Failed to parse JSON metadata:', e);
        }
      }
      
      delete targetRes.headers['transfer-encoding'];
      res.writeHead(targetRes.statusCode, targetRes.headers);
      res.end(data);
    });
  });
  
  targetReq.on('error', (err) => {
    console.error('[Proxy] Error forwarding request:', err);
    res.writeHead(500);
    res.end('Error forwarding request');
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[Proxy] Server listening on http://127.0.0.1:${PORT}`);
});
