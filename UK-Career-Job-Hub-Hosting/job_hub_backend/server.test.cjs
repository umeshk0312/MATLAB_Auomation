const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { matchesKeyword, safeUrl, loadSources, searchUrl, extractJobs, searchSource, createServer,
    validateSources, publicPortalUrl, isPublicAddress, parseKeywords, runtimeConfig } = require('./server.cjs');

test('hosting configuration supports the public HTTPS origin and platform-provided port', () => {
    const local = runtimeConfig({});
    assert.equal(local.host, '127.0.0.1');
    assert.equal(local.port, 8765);
    const hosted = runtimeConfig({ PORT: '10000', RENDER_EXTERNAL_URL: 'https://job-hub.onrender.com' });
    assert.equal(hosted.host, '0.0.0.0');
    assert.equal(hosted.port, 10000);
    assert.equal(hosted.publicOrigin, 'https://job-hub.onrender.com');
    assert.equal(hosted.maxConcurrentSearches, 1);
    assert.ok(!hosted.allowPortFallback);
    assert.throws(() => runtimeConfig({ PORT: 'not-a-port' }));
    assert.throws(() => runtimeConfig({ PUBLIC_ORIGIN: 'http://example.com' }));
    assert.throws(() => runtimeConfig({ PUBLIC_ORIGIN: 'https://example.com/private' }));
});

test('hosted health and search work without a password while unrelated hosts and origins are denied', async () => {
    const server = createServer({ publicOrigin: 'https://job-hub.onrender.com' });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = 'http://127.0.0.1:' + server.address().port;
    const headers = { Host: 'job-hub.onrender.com', Origin: 'https://job-hub.onrender.com', 'Content-Type': 'application/json' };
    const request = (pathname, options = {}) => new Promise((resolve, reject) => {
        const outbound = http.request(base + pathname, { method: options.method || 'GET', headers: { ...headers, ...options.headers } }, response => {
            let text = '';
            response.setEncoding('utf8');
            response.on('data', chunk => { text += chunk; });
            response.on('end', () => resolve({ status: response.statusCode, text }));
        });
        outbound.on('error', reject);
        outbound.end(options.body);
    });
    try {
        const health = await request('/healthz');
        assert.equal(health.status, 200);
        assert.deepEqual(JSON.parse(health.text), { status: 'ok' });
        const search = await request('/api/search', { method: 'POST',
            body: JSON.stringify({ keyword: 'matlab', sources: [] }) });
        assert.equal(search.status, 200);
        assert.match(search.text, /"type":"done"/);
        assert.equal((await request('/healthz', { headers: { Host: 'unrelated.example.com' } })).status, 403);
        assert.equal((await request('/healthz', { headers: { Origin: 'https://unrelated.example.com' } })).status, 403);
    } finally { await new Promise(resolve => server.close(resolve)); }
});

test('public search has a request-start rate limit without requiring user accounts', async () => {
    const server = createServer({ searchStartsPerMinute: 1 });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = 'http://127.0.0.1:' + server.address().port;
    const options = { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ keyword: 'matlab', sources: [] }) };
    try {
        const first = await fetch(base + '/api/search', options);
        assert.equal(first.status, 200);
        await first.text();
        const second = await fetch(base + '/api/search', options);
        assert.equal(second.status, 429);
        assert.equal(second.headers.get('retry-after'), '15');
        assert.match((await second.json()).message, /capacity/);
        assert.equal((await fetch(base + '/healthz')).status, 200);
    } finally { await new Promise(resolve => server.close(resolve)); }
});

test('hosted search capacity is released when a visitor cancels a running search', async context => {
    const nativeFetch = global.fetch;
    context.mock.method(global, 'fetch', (url, options) => new Promise((resolve, reject) => {
        options.signal.addEventListener('abort', () => reject(new Error('Cancelled')), { once: true });
    }));
    const server = createServer({ maxConcurrentSearches: 1 });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = 'http://127.0.0.1:' + server.address().port;
    const controller = new AbortController();
    const closed = new Promise(resolve => server.once('request', (req, res) => res.once('close', resolve)));
    const empty = { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ keyword: 'matlab', sources: [] }) };
    try {
        const first = await nativeFetch(base + '/api/search', { ...empty, signal: controller.signal,
            body: JSON.stringify({ keyword: 'matlab', sources: [{ company: 'Test', url: 'https://example.com/careers' }] }) });
        assert.equal(first.status, 200);
        const second = await nativeFetch(base + '/api/search', empty);
        assert.equal(second.status, 429);
        await second.text();
        controller.abort();
        await closed;
        const third = await nativeFetch(base + '/api/search', empty);
        assert.equal(third.status, 200);
        await third.text();
    } finally {
        controller.abort();
        await new Promise(resolve => server.close(resolve));
    }
});

test('editable company lists preserve additions and removals and reject invalid entries', () => {
    const sources = validateSources([{ company: ' New Company ', url: 'https://careers.example.com/jobs' }]);
    assert.deepEqual(sources, [{ company: 'New Company', url: 'https://careers.example.com/jobs' }]);
    assert.deepEqual(validateSources([]), []);
    assert.throws(() => validateSources([{ company: '', url: 'https://example.com' }]));
    assert.throws(() => validateSources([sources[0], sources[0]]));
    assert.throws(() => validateSources(Array(101).fill(sources[0])));
    for (const url of ['http://example.com', 'https://localhost', 'https://127.0.0.1',
        'https://192.168.1.1', 'https://[::1]', 'https://portal.local', 'https://user:pass@example.com', 'https://example.com:8443']) {
        assert.throws(() => publicPortalUrl(url), url);
    }
});

test('portal connections reject private and reserved DNS destinations', () => {
    for (const address of ['127.0.0.1', '10.0.0.1', '172.16.0.1', '192.168.1.1', '169.254.169.254', '100.64.1.1', '::1', 'fc00::1', '::ffff:127.0.0.1']) {
        assert.equal(isPublicAddress(address), false, address);
    }
    assert.ok(isPublicAddress('8.8.8.8'));
    assert.ok(isPublicAddress('2606:4700:4700::1111'));
});

test('all original company portals remain available', () => {
    const sources = loadSources();
    assert.equal(sources.length, 39);
    assert.equal(new Set(sources.map(source => source.company)).size, 39);
});

test('keywords match job text, not just portal URLs', () => {
    assert.ok(matchesKeyword('Senior MATLAB / Simulink Engineer', 'matlab simulink'));
    assert.ok(!matchesKeyword('Software Engineer', 'matlab'));
});

test('comma-separated keywords match either term regardless of spacing or case', () => {
    assert.deepEqual(parseKeywords(' Matlab,simulink, MATLAB, , '), ['Matlab', 'simulink']);
    for (const query of ['Matlab, Simulink', 'Matlab,simulink']) {
        assert.ok(matchesKeyword('MATLAB Engineer', query));
        assert.ok(matchesKeyword('Simulink Engineer', query));
        assert.ok(!matchesKeyword('Mechanical Engineer', query));
    }
    assert.ok(matchesKeyword('Embedded control software', 'embedded software, matlab'));
    assert.ok(!matchesKeyword('Embedded hardware', 'embedded software, matlab'));
    assert.ok(!matchesKeyword('MATLAB Engineer', ', ,'));
    assert.throws(() => parseKeywords('a,b,c,d,e,f,g,h,i,j,k'));
});

test('multi-keyword searches query portals separately and merge duplicate job URLs', async () => {
    const visited = [];
    const shared = { title: 'Controls Engineer', url: 'https://example.com/job/shared' };
    const result = await searchSource({ company: 'Test', url: 'https://example.com' }, 'Matlab,simulink, MATLAB',
        new AbortController().signal, { generic: async (source, term) => {
            visited.push(term);
            return { status: 'searched', jobs: [shared, { title: term + ' Engineer', url: 'https://example.com/job/' + term.toLowerCase() }] };
        } });
    assert.deepEqual(visited, ['Matlab', 'simulink']);
    assert.equal(result.jobs.length, 3);
    assert.equal(result.status, 'searched');
});

test('a failed keyword search retains successful matches and reports partial coverage', async () => {
    const result = await searchSource({ company: 'Test', url: 'https://example.com' }, 'matlab, simulink',
        new AbortController().signal, { generic: async (source, term) => {
            if (term === 'simulink') throw new Error('blocked');
            return { status: 'searched', jobs: [{ title: 'MATLAB Engineer', url: 'https://example.com/job/1' }] };
        } });
    assert.equal(result.jobs.length, 1);
    assert.equal(result.status, 'partial');
    assert.match(result.message, /1 unavailable/);
});

test('search URLs preserve location and safely encode arbitrary keywords', () => {
    const url = new URL(searchUrl({ url: 'https://example.com/jobs?q=old&country=India&pid=42&utm_source=ad' }, 'C++ & controls'));
    assert.equal(url.searchParams.get('q'), 'C++ & controls');
    assert.equal(url.searchParams.get('country'), 'India');
    assert.ok(!url.searchParams.has('pid'));
    assert.ok(!url.searchParams.has('utm_source'));
    const hashUrl = new URL(searchUrl({ url: 'https://example.com/#/?searchTerm=old&location=India' }, 'Simulink'));
    assert.equal(new URLSearchParams(hashUrl.hash.slice(3)).get('searchTerm'), 'Simulink');
    const expleo = new URL(searchUrl({ url: 'https://expleo-jobs-in-en.icims.com/jobs/search?searchKeyword=MBD&searchLocation=13228-13248-Pune' }, 'MATLAB'));
    assert.equal(expleo.searchParams.get('searchKeyword'), 'MATLAB');
    assert.equal(expleo.searchParams.get('searchLocation'), '13228-13248-Pune');
});

test('broader scanning follows pagination and checks description matches beyond the original 12-job limit', async context => {
    const visited = [];
    context.mock.method(global, 'fetch', async url => {
        const target = new URL(url);
        visited.push(target.href);
        let html;
        if (target.pathname === '/careers') {
            html = '<a rel="next" href="?page=2">Next</a>';
        }
        if (target.pathname === '/careers' && target.searchParams.get('page') === '2') {
            html = Array.from({ length: 15 }, (value, index) => '<a href="/job/' + index + '">Controls Engineer ' + index + '</a>').join('');
        }
        if (target.pathname.startsWith('/job/')) {
            html = '<h1>Controls Engineer</h1><div class="jobdescription">' + (target.pathname === '/job/14' ? 'MATLAB' : 'Mechanical design') + '</div>';
        }
        const response = new Response(html || '');
        Object.defineProperty(response, 'url', { value: target.href });
        return response;
    });
    const result = await searchSource({ company: 'Future Company', url: 'https://careers.example.com/careers?country=India' }, 'matlab', new AbortController().signal);
    assert.equal(result.jobs.length, 1);
    assert.equal(result.jobs[0].url, 'https://careers.example.com/job/14');
    assert.ok(visited.includes('https://careers.example.com/careers?page=2&country=India'));
    assert.match(result.message, /15 job pages checked/);
});

test('keyword forms keep saved location filters and embedded ATS boards are discovered automatically', async context => {
    const visited = [];
    context.mock.method(global, 'fetch', async url => {
        const target = new URL(url);
        visited.push(target.href);
        let html = '';
        if (target.pathname === '/careers') html = '<iframe title="Careers" src="https://future-company.icims.com/jobs/search?searchKeyword=old&searchLocation=Pune"></iframe>';
        if (target.hostname === 'future-company.icims.com') {
            html = '<form action="/jobs/search"><input name="searchKeyword" type="text"></form>' +
                '<a href="/jobs/42/controls-engineer/job">Controls Engineer</a>';
        }
        if (target.pathname === '/jobs/42/controls-engineer/job') html = '<h1>Controls Engineer</h1><div class="iCIMS_JobContent">MATLAB</div>';
        const response = new Response(html);
        Object.defineProperty(response, 'url', { value: target.href });
        return response;
    });
    const result = await searchSource({ company: 'Future Company', url: 'https://example.com/careers' }, 'matlab', new AbortController().signal);
    assert.equal(result.jobs.length, 1);
    assert.ok(visited.includes('https://future-company.icims.com/jobs/search?searchKeyword=matlab&searchLocation=Pune'));
    assert.ok(!visited.some(url => url.includes('searchKeyword=old')));
});

test('page failures preserve earlier matches and do not claim complete coverage', async context => {
    context.mock.method(global, 'fetch', async url => {
        if (String(url).includes('page=2')) throw new Error('blocked');
        const response = new Response('<h1>MATLAB Engineer</h1><div class="jobdescription">MATLAB</div><a rel="next" href="?page=2">Next</a>');
        Object.defineProperty(response, 'url', { value: String(url) });
        return response;
    });
    const result = await searchSource({ company: 'Future Company', url: 'https://example.com/careers' }, 'matlab', new AbortController().signal);
    assert.equal(result.jobs.length, 1);
    assert.equal(result.status, 'partial');
    assert.match(result.message, /1 page requests failed/);
});

test('listing pagination stops at the shared limit instead of crawling indefinitely', async context => {
    let requests = 0;
    context.mock.method(global, 'fetch', async url => {
        requests++;
        const target = new URL(url);
        const nextPage = Number(target.searchParams.get('page') || 1) + 1;
        const response = new Response('<a rel="next" href="?page=' + nextPage + '">Next</a>');
        Object.defineProperty(response, 'url', { value: target.href });
        return response;
    });
    const result = await searchSource({ company: 'Future Company', url: 'https://example.com/careers' }, 'matlab', new AbortController().signal);
    assert.equal(requests, 8);
    assert.equal(result.status, 'partial');
    assert.match(result.message, /scan limit or timeout/);
});

test('multiple keyword searches reuse shared job pages without duplicate vacancies', async context => {
    let jobReads = 0;
    context.mock.method(global, 'fetch', async url => {
        const target = new URL(url);
        let html = '<a href="/openings/shared">Controls Engineer</a>';
        if (target.pathname === '/openings/shared') {
            jobReads++;
            html = '<h1>Controls Engineer</h1><div class="jobdescription">MATLAB and Simulink</div>';
        }
        const response = new Response(html);
        Object.defineProperty(response, 'url', { value: target.href });
        return response;
    });
    const result = await searchSource({ company: 'Future Company', url: 'https://example.com/careers?searchKeyword=old' }, 'matlab,simulink', new AbortController().signal);
    assert.equal(jobReads, 1);
    assert.equal(result.jobs.length, 1);
});

test('an access-block page is unavailable rather than a completed zero-match search', async context => {
    context.mock.method(global, 'fetch', async url => {
        const response = new Response('<title>Access Denied</title><p>Interactive login required.</p>');
        Object.defineProperty(response, 'url', { value: String(url) });
        return response;
    });
    const result = await searchSource({ company: 'Future Company', url: 'https://example.com/careers' }, 'matlab', new AbortController().signal);
    assert.equal(result.status, 'unavailable');
    assert.equal(result.jobs.length, 0);
});

test('Workday pagination retrieves matches beyond the previous 100-result limit', async context => {
    const offsets = [];
    context.mock.method(global, 'fetch', async (url, options) => {
        const { offset } = JSON.parse(options.body);
        offsets.push(offset);
        const jobPostings = Array.from({ length: 20 }, (value, index) => ({
            title: 'MATLAB Engineer ' + (offset + index), externalPath: '/job/role-' + (offset + index)
        }));
        const response = new Response(JSON.stringify({ total: 120, jobPostings }));
        Object.defineProperty(response, 'url', { value: String(url) });
        return response;
    });
    const result = await searchSource({ company: 'Future Company', url: 'https://future.myworkdayjobs.com/en-US/Careers' }, 'matlab', new AbortController().signal);
    assert.equal(result.jobs.length, 120);
    assert.equal(result.status, 'searched');
    assert.deepEqual(offsets, [0, 20, 40, 60, 80, 100]);
});

test('structured job extraction handles graphs, descriptions, expired jobs and unsafe links', () => {
    const posting = { '@type': 'JobPosting', title: 'Controls Engineer', description: '<p>MATLAB &amp; Simulink</p>',
        url: '/jobs/42', jobLocation: { address: { addressLocality: 'Pune', addressCountry: 'IN' } } };
    const html = '<script type="application/ld+json">' + JSON.stringify({ '@graph': [posting,
        { ...posting, url: '/jobs/expired', validThrough: '2000-01-01' },
        { ...posting, url: 'javascript:alert(1)' }] }) + '</script>';
    const jobs = extractJobs(html, 'https://example.com', 'matlab');
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].url, 'https://example.com/jobs/42');
    assert.equal(jobs[0].location, 'Pune, IN');
    assert.equal(extractJobs(html, 'https://example.com', 'mechanical').length, 0);
    assert.equal(safeUrl('javascript:alert(1)'), null);
    const expiredHtml = '<h1>MATLAB Engineer</h1><div class="jobdescription">MATLAB</div>' +
        '<script type="application/ld+json">' + JSON.stringify({ ...posting, validThrough: '2000-01-01' }) + '</script>';
    assert.equal(extractJobs(expiredHtml, 'https://example.com/job/expired', 'matlab').length, 0);
});

test('malformed structured data does not prevent other valid postings', () => {
    const html = '<script type="application/ld+json">bad json</script>' +
        '<script type="application/ld+json">{"@type":"JobPosting","title":"MATLAB Engineer","url":"/jobs/1"}</script>';
    assert.equal(extractJobs(html, 'https://example.com', 'matlab').length, 1);
});

test('job descriptions match keywords absent from the job title', () => {
    const html = '<h1>Embedded Software Integration Engineer</h1><div class="jobdescription">Experience in MATLAB and Simulink.</div>';
    const jobs = extractJobs(html, 'https://example.com/job/123', 'matlab');
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0].title, 'Embedded Software Integration Engineer');
    assert.equal(extractJobs(html, 'https://example.com/job/123', 'mechanical').length, 0);
    const metadataHtml = '<meta property="og:title" content="Controls Engineer"><div class="jobdescription">MATLAB</div>';
    assert.equal(extractJobs(metadataHtml, 'https://example.com/job/456', 'matlab')[0].title, 'Controls Engineer');
});

test('source errors are unavailable, never reported as zero matching jobs', async () => {
    const source = { company: 'Test', url: 'https://example.com' };
    const result = await searchSource(source, 'matlab', new AbortController().signal,
        { generic: async () => { throw new Error('blocked'); } });
    assert.equal(result.status, 'unavailable');
    assert.deepEqual(result.jobs, []);
});

test('named keyword fields in GET forms submit a live search without using location fields', async context => {
    const urls = [];
    context.mock.method(global, 'fetch', async url => {
        urls.push(String(url));
        const html = urls.length === 1 ?
            '<form action="/search/" method="get"><input type="text" name="q"><input type="text" name="locationsearch"></form>' :
            '<h1>Controls Engineer</h1><div class="jobdescription">MATLAB</div>';
        const response = new Response(html);
        Object.defineProperty(response, 'url', { value: String(url) });
        return response;
    });
    const result = await searchSource({ company: 'Test', url: 'https://example.com' }, 'matlab', new AbortController().signal);
    assert.equal(urls.length, 2);
    assert.equal(new URL(urls[1]).pathname, '/search/');
    assert.equal(new URL(urls[1]).searchParams.get('q'), 'matlab');
    assert.ok(!new URL(urls[1]).searchParams.has('locationsearch'));
    assert.equal(result.jobs.length, 1);
});

test('source results are deduplicated and retain company attribution', async () => {
    const job = { title: 'MATLAB Engineer', url: 'https://example.com/jobs/1' };
    const result = await searchSource({ company: 'Test', url: 'https://example.com' }, 'matlab',
        new AbortController().signal, { generic: async () => ({ jobs: [job, job], status: 'partial' }) });
    assert.equal(result.jobs.length, 1);
    assert.equal(result.jobs[0].company, 'Test');
});

test('POST search checks only the submitted companies, including newly added portals', async context => {
    const nativeFetch = global.fetch;
    const visited = [];
    context.mock.method(global, 'fetch', async url => {
        visited.push(String(url));
        const response = new Response('<h1>Controls Engineer</h1><div class="jobdescription">MATLAB</div>');
        Object.defineProperty(response, 'url', { value: String(url) });
        return response;
    });
    const server = createServer();
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    try {
        const response = await nativeFetch('http://127.0.0.1:' + server.address().port + '/api/search', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ keyword: 'matlab', sources: [{ company: 'Added Portal', url: 'https://careers.example.com/jobs' }] })
        });
        assert.equal(response.status, 200);
        const events = (await response.text()).trim().split('\n').map(line => JSON.parse(line));
        assert.equal(events[0].total, 1);
        const source = events.find(event => event.type === 'source');
        assert.equal(source.company, 'Added Portal');
        assert.equal(source.jobs.length, 1);
        assert.deepEqual(visited, ['https://careers.example.com/jobs']);
        assert.equal(events.at(-1).type, 'done');
    } finally {
        await new Promise(resolve => server.close(resolve));
    }
});

test('local HTTP server serves the page and rejects invalid search and foreign origins', async () => {
    const server = createServer();
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const base = 'http://127.0.0.1:' + server.address().port;
    try {
        assert.equal((await fetch(base)).status, 200);
        assert.equal((await fetch(base + '/api/search?q=%20')).status, 400);
        assert.equal((await fetch(base + '/api/search?q=%2C%20%2C')).status, 400);
        assert.equal((await fetch(base + '/api/search?q=a,b,c,d,e,f,g,h,i,j,k')).status, 400);
        assert.equal((await fetch(base + '/api/search?q=matlab', { headers: { Origin: 'https://example.com' } })).status, 403);
        assert.equal((await fetch(base + '/missing')).status, 404);
        const icons = await fetch(base + '/lucide.js');
        assert.equal(icons.status, 200);
        assert.match(await icons.text(), /createIcons/);
        const emptySearch = await fetch(base + '/api/search', { method: 'POST',
            headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ keyword: 'matlab', sources: [] }) });
        assert.equal(emptySearch.status, 200);
        const events = (await emptySearch.text()).trim().split('\n').map(line => JSON.parse(line));
        assert.equal(events[0].total, 0);
        assert.equal(events.at(-1).type, 'done');
        assert.equal((await fetch(base + '/api/search', { method: 'POST', body: '{bad' })).status, 400);
        assert.equal((await fetch(base + '/api/search', { method: 'POST',
            body: JSON.stringify({ keyword: 'matlab', sources: [{ company: 'Local', url: 'https://127.0.0.1' }] }) })).status, 400);
    } finally {
        await new Promise(resolve => server.close(resolve));
    }
});