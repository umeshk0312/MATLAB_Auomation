const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const cheerio = require('cheerio');
const dns = require('node:dns');
const net = require('node:net');
const { Agent } = require('undici');

const pagePath = path.join(__dirname, '..', 'job_hub.html');
const MAX_JOBS = 500;
const MAX_LISTING_PAGES = 8;
const MAX_DETAIL_PAGES = 100;
const PORTAL_LIMIT = 60000;
const KEYWORD_FIELD = /^(?:q|query|keywords?|search(?:term|word|keywords?|text)?|PositionFormattedDescription\.Content)$/i;

function runtimeConfig(environment = process.env) {
    const configuredOrigin = environment.PUBLIC_ORIGIN || environment.RENDER_EXTERNAL_URL || '';
    let publicOrigin = '';
    if (configuredOrigin) {
        const url = new URL(configuredOrigin);
        if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash) {
            throw new Error('PUBLIC_ORIGIN must be an HTTPS origin without a path, credentials or query.');
        }
        publicOrigin = url.origin;
    }
    const port = environment.PORT ? Number(environment.PORT) : publicOrigin ? 10000 : 8765;
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be between 1 and 65535.');
    return { publicOrigin, port, host: publicOrigin ? '0.0.0.0' : '127.0.0.1',
        allowPortFallback: !publicOrigin && !environment.PORT,
        parallelPortals: publicOrigin ? 2 : 6, maxConcurrentSearches: publicOrigin ? 1 : 2,
        searchStartsPerMinute: 10 };
}

function isJobBoard(url) {
    return /(?:^|\.)(?:icims\.com|myworkdayjobs\.com|smartrecruiters\.com|successfactors\.com|eightfold\.ai|greenhouse\.io|lever\.co)$/.test(new URL(url).hostname);
}

function isPublicAddress(address) {
    if (net.isIP(address) === 6) return /^[23]/i.test(address) && !/^2001:(?:db8|0):/i.test(address);
    if (net.isIP(address) !== 4) return false;
    const octets = address.split('.').map(Number);
    return !(octets[0] === 0 || octets[0] === 10 || octets[0] === 127 || octets[0] >= 224 ||
        (octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127) ||
        (octets[0] === 169 && octets[1] === 254) ||
        (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
        (octets[0] === 192 && (octets[1] === 168 || octets[1] === 0)) ||
        (octets[0] === 198 && (octets[1] === 18 || octets[1] === 19 || octets[1] === 51)) ||
        (octets[0] === 203 && octets[1] === 0 && octets[2] === 113));
}

function publicPortalUrl(value) {
    if (typeof value !== 'string' || value.length > 2048) throw new Error('Enter a valid public HTTPS career URL.');
    let url;
    try { url = new URL(value); } catch { throw new Error('Enter a valid public HTTPS career URL.'); }
    const hostname = url.hostname.replace(/\.$/, '').toLowerCase();
    if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') ||
        !hostname.includes('.') || net.isIP(hostname) || hostname.startsWith('[') ||
        /(?:^|\.)(?:localhost|local|internal|test|invalid)$/.test(hostname)) {
        throw new Error('Company URLs must use public HTTPS domains without credentials or custom ports.');
    }
    return url.href;
}

const portalDispatcher = new Agent({ connect: { lookup(hostname, options, callback) {
    dns.lookup(hostname, { all: true }, (error, addresses) => {
        if (error) return callback(error);
        if (!addresses.length || addresses.some(item => !isPublicAddress(item.address))) {
            return callback(new Error('Private or reserved network destinations are not allowed.'));
        }
        if (options.all) return callback(null, addresses);
        const selected = addresses.find(item => !options.family || item.family === options.family);
        if (!selected) return callback(new Error('No supported public address was found.'));
        callback(null, selected.address, selected.family);
    });
} } });

function validateSources(value) {
    if (!Array.isArray(value) || value.length > 100) throw new Error('Use a company list with at most 100 entries.');
    const names = new Set();
    const urls = new Set();
    return value.map(source => {
        if (!source || typeof source.company !== 'string' || !source.company.trim() || source.company.trim().length > 100) {
            throw new Error('Company names must contain 1 to 100 characters.');
        }
        const company = source.company.trim();
        const url = publicPortalUrl(source.url);
        if (names.has(company.toLowerCase()) || urls.has(url)) throw new Error('Remove duplicate companies or portal URLs.');
        names.add(company.toLowerCase());
        urls.add(url);
        return { company, url };
    });
}

async function readJsonBody(req) {
    let size = 0;
    const chunks = [];
    for await (const chunk of req) {
        size += chunk.length;
        if (size > 256000) throw new Error('Company list is too large.');
        chunks.push(chunk);
    }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new Error('Invalid search request.'); }
}

function parseKeywords(value) {
    const unique = new Map();
    for (const entry of String(value).normalize('NFKC').split(',')) {
        const keyword = entry.trim().replace(/\s+/g, ' ');
        if (keyword && !unique.has(keyword.toLowerCase())) unique.set(keyword.toLowerCase(), keyword);
    }
    if (unique.size > 10) throw new Error('Search at most 10 comma-separated keywords at a time.');
    return [...unique.values()];
}

function matchesKeyword(text, keyword) {
    const normalized = String(text).normalize('NFKC').toLowerCase();
    return parseKeywords(keyword).some(entry => entry.toLowerCase().split(/\s+/)
        .every(term => normalized.includes(term)));
}

function safeUrl(value, base) {
    try {
        const url = new URL(value, base);
        return url.protocol === 'https:' ? url.href : null;
    } catch {
        return null;
    }
}

function loadSources() {
    const document = cheerio.load(fs.readFileSync(pagePath, 'utf8'));
    return document('#jobTableBody tr').toArray().map(row => ({
        company: document(row).find('strong').text().trim(),
        url: document(row).find('a.job-link').attr('href')
    })).filter(source => source.company && safeUrl(source.url));
}

function searchUrl(source, keyword) {
    const url = new URL(source.url);
    for (const key of [...url.searchParams.keys()]) {
        if (/^(utm_|gad_|gclid|gbraid)/i.test(key)) url.searchParams.delete(key);
    }
    const fragment = url.hash.startsWith('#/?') ? new URLSearchParams(url.hash.slice(3)) : null;
    let replaced = false;
    for (const parameters of [url.searchParams, fragment].filter(Boolean)) {
        for (const key of [...parameters.keys()]) {
            if (KEYWORD_FIELD.test(key)) {
                parameters.set(key, keyword);
                replaced = true;
            }
        }
    }
    if (fragment) url.hash = '/?' + fragment.toString();
    if (replaced) {
        url.searchParams.delete('pid');
        for (const key of [...url.searchParams.keys()]) {
            if (/^(start|offset|skip|in_offset)$/i.test(key)) url.searchParams.set(key, '0');
            if (/^(page|pageNumber|pageIndex)$/i.test(key)) url.searchParams.set(key, /index/i.test(key) ? '0' : '1');
        }
    }
    return url.href;
}

async function request(url, signal, body) {
    let target = publicPortalUrl(url);
    let response;
    const requestSignal = AbortSignal.any([signal, AbortSignal.timeout(10000)]);
    for (let redirects = 0; redirects <= 5; redirects++) {
        response = await fetch(target, {
        dispatcher: portalDispatcher,
        redirect: 'manual',
        signal: requestSignal,
        headers: {
            'User-Agent': 'LocalCareerSearch/1.0',
            Accept: body ? 'application/json' : 'text/html,application/json',
            ...(body ? { 'Content-Type': 'application/json' } : {})
        },
        ...(body ? { method: 'POST', body: JSON.stringify(body) } : {})
        });
        if (![301, 302, 303, 307, 308].includes(response.status)) break;
        const location = response.headers.get('location');
        await response.body?.cancel();
        if (!location || redirects === 5) throw new Error('Portal redirect could not be followed.');
        const redirected = publicPortalUrl(new URL(location, target).href);
        if (body && new URL(redirected).origin !== new URL(target).origin) throw new Error('Cross-site API redirect is not supported.');
        if ([301, 302, 303].includes(response.status)) body = undefined;
        target = redirected;
    }
    if (!response.ok) throw new Error('Portal returned HTTP ' + response.status);
    const reader = response.body.getReader();
    const chunks = [];
    let size = 0;
    try {
        while (true) {
            const chunk = await reader.read();
            if (chunk.done) break;
            size += chunk.value.length;
            if (size > 6000000) throw new Error('Portal response exceeded size limit');
            chunks.push(Buffer.from(chunk.value));
        }
    } finally {
        await reader.cancel().catch(() => {});
    }
    const text = Buffer.concat(chunks).toString('utf8');
    const document = cheerio.load(text);
    const title = document('title').text();
    if (/^(?:just a moment|access denied|request blocked|web access blocked|authentication required)/i.test(title.trim()) ||
        /^(?:gateway|login)\.zscloud\.net$/i.test(new URL(response.url || target).hostname)) {
        throw new Error('Portal requires interactive browser access.');
    }
    return { text, url: response.url || target };
}

function extractJobs(html, base, keyword, now = Date.now()) {
    const document = cheerio.load(html);
    const jobs = [];
    let hasStructuredPosting = false;
    function visit(value) {
        if (!value || typeof value !== 'object') return;
        if (Array.isArray(value)) {
            value.forEach(visit);
            return;
        }
        const types = [].concat(value['@type'] || []);
        if (types.includes('JobPosting')) {
            hasStructuredPosting = true;
            const title = cheerio.load(String(value.title || '')).text().trim();
            const description = cheerio.load(String(value.description || '')).text();
            const expired = value.validThrough && Date.parse(value.validThrough) < now;
            const url = safeUrl(value.url || value['@id'] || base, base);
            const locations = [].concat(value.jobLocation || []).map(location => {
                const address = location.address || {};
                return [address.addressLocality, address.addressRegion, address.addressCountry]
                    .filter(item => typeof item === 'string').join(', ');
            }).filter(Boolean);
            if (!expired && title && url && matchesKeyword(title + ' ' + description, keyword)) {
                jobs.push({ title, url, location: locations.join(' / ') ||
                    (value.jobLocationType === 'TELECOMMUTE' ? 'Remote' : 'Not specified'),
                    evidence: 'Job posting', posted: value.datePosted || '' });
            }
        }
        Object.values(value).forEach(visit);
    }
    document('script[type="application/ld+json"]').each((index, element) => {
        try { visit(JSON.parse(document(element).text())); } catch {}
    });
    if (!hasStructuredPosting) {
        const description = document('.jobdescription, [itemprop="description"], .job-description, .jobDescription, .iCIMS_JobContent').first().text().trim();
        const title = (document('h1').first().text().trim() ||
            document('meta[property="og:title"]').attr('content') || '').replace(/\s+/g, ' ').trim();
        const url = safeUrl(base);
        const expired = document('meta[itemprop="validThrough"]').attr('content');
        if (description && title && url && !(expired && Date.parse(expired) < now) &&
            matchesKeyword(title + ' ' + description, keyword)) {
            jobs.push({ title, url, evidence: 'Portal job description',
                location: document('[itemprop="jobLocation"], .jobGeoLocation').first().text().trim() || 'Not specified',
                posted: document('meta[itemprop="datePosted"]').attr('content') || '' });
        }
    }
    return jobs;
}

async function workdaySearch(source, keyword, signal) {
    const original = new URL(source.url);
    const board = original.pathname.split('/').filter(Boolean).pop();
    const tenant = original.hostname.split('.')[0];
    const endpoint = original.origin + '/wday/cxs/' + tenant + '/' + board + '/jobs';
    const appliedFacets = {};
    for (const key of ['locationCountry', 'timeType', 'jobFamilyGroup']) {
        if (original.searchParams.has(key)) appliedFacets[key] = original.searchParams.getAll(key);
    }
    const jobs = [];
    let total = 0;
    let offset = 0;
    do {
        const response = await request(endpoint, signal, {
            appliedFacets, limit: 20, offset, searchText: keyword
        });
        const data = JSON.parse(response.text);
        if (!Array.isArray(data.jobPostings)) throw new Error('Unrecognized Workday response');
        total = Number(data.total) || 0;
        for (const posting of data.jobPostings) {
            const url = safeUrl(original.origin + '/' + board + posting.externalPath);
            if (posting.title && posting.externalPath && url) jobs.push({
                title: posting.title, url, location: posting.locationsText || 'Not specified',
                evidence: 'Live portal search', posted: posting.postedOn || ''
            });
        }
        if (!data.jobPostings.length) break;
        offset += data.jobPostings.length;
    } while (offset < total && offset < MAX_JOBS);
    return { jobs, status: offset >= total ? 'searched' : 'partial',
        message: offset >= total ? 'Live search completed with saved portal filters.' :
            'Up to 500 results retrieved; more may be available on the portal.' };
}

async function genericSearch(source, keyword, signal, context = { pages: new Map(), cacheBytes: 0 }) {
    const jobs = [];
    const queue = [searchUrl(source, keyword)];
    const scheduled = new Set(queue);
    const visited = new Set();
    const candidates = new Map();
    let listingPages = 0;
    let detailPages = 0;
    let failedRequests = 0;
    const loadPage = url => {
        if (!context.pages.has(url)) {
            const pending = request(url, signal).then(response => {
                const bytes = Buffer.byteLength(response.text, 'utf8');
                if ((context.cacheBytes || 0) + bytes <= 8000000) context.cacheBytes = (context.cacheBytes || 0) + bytes;
                else context.pages.delete(url);
                return response;
            });
            context.pages.set(url, pending);
        }
        return context.pages.get(url);
    };
    const linkedUrl = (value, base, embedded = false) => {
        const url = safeUrl(value, base);
        if (!url) return null;
        try { publicPortalUrl(url); } catch { return null; }
        const target = new URL(url);
        if (target.origin !== new URL(base).origin && !(embedded && isJobBoard(url))) return null;
        if (/\/(?:apply|login|register|signin|sign-in|account)(?:\/|$)/i.test(target.pathname)) return null;
        target.hash = '';
        return target.href;
    };
    const schedule = url => {
        if (url && !scheduled.has(url)) { scheduled.add(url); queue.push(url); }
    };
    while (queue.length && listingPages < MAX_LISTING_PAGES && !signal.aborted) {
        const url = queue.shift();
        if (visited.has(url)) continue;
        visited.add(url);
        let response;
        try { response = await loadPage(url); } catch (error) {
            if (!listingPages) throw error;
            failedRequests++;
            continue;
        }
        listingPages++;
        const document = cheerio.load(response.text);
        jobs.push(...extractJobs(response.text, response.url, keyword));
        for (const element of document('form').toArray()) {
            const form = document(element);
            if ((form.attr('method') || 'get').toLowerCase() !== 'get') continue;
            const field = form.find('input[name]').toArray().find(input =>
                document(input).attr('type') === 'search' || KEYWORD_FIELD.test(document(input).attr('name')));
            if (!field) continue;
            const action = linkedUrl(form.attr('action') || response.url, response.url);
            if (!action) continue;
            const target = new URL(action);
            const current = new URL(response.url);
            for (const [key, value] of current.searchParams) {
                if (!target.searchParams.has(key)) target.searchParams.append(key, value);
            }
            form.find('input[type="hidden"][name], select[name]').each((index, input) => {
                const control = document(input);
                const value = control.val();
                if (!target.searchParams.has(control.attr('name')) && typeof value === 'string' && value) {
                    target.searchParams.set(control.attr('name'), value);
                }
            });
            target.searchParams.set(document(field).attr('name'), keyword);
            schedule(target.href);
            break;
        }
        document('iframe[src]').each((index, element) => {
            const frame = document(element);
            if (/job|career|icims|recruit/i.test([frame.attr('src'), frame.attr('id'), frame.attr('title')].join(' '))) {
                const embedded = linkedUrl(frame.attr('src'), response.url, true);
                if (embedded) schedule(searchUrl({ url: embedded }, keyword));
            }
        });
        document('a[href], link[rel~="next"][href]').each((index, element) => {
            const anchor = document(element);
            const targetUrl = linkedUrl(anchor.attr('href'), response.url, true);
            if (!targetUrl) return;
            const target = new URL(targetUrl);
            const title = anchor.text().replace(/\s+/g, ' ').trim();
            const pagination = /(?:^|\s)next(?:\s|$)/i.test(anchor.attr('rel') || '') ||
                /^next(?:\s|$|[>»])/i.test(title) ||
                /next.*page|next page/i.test(anchor.attr('aria-label') || '') ||
                anchor.closest('.pagination, .pager, .iCIMS_Paginator').length > 0;
            if (pagination && target.origin === new URL(response.url).origin) {
                for (const [key, value] of new URL(response.url).searchParams) {
                    if (!target.searchParams.has(key)) target.searchParams.append(key, value);
                }
                schedule(target.href);
                return;
            }
            const pathMatch = target.pathname.match(/\/(?:jobs?|jobdetail|job-details|requisitions?|positions?|vacanc(?:y|ies)|openings?|opportunities)\/([^/?#]+)/i);
            const jobPath = pathMatch && !/^(?:search|search-results|current-openings|job-openings|apply|login|register)$/i.test(pathMatch[1]);
            const jobParameter = [...target.searchParams.keys()].some(key => /^(?:jobId|job_id|requisitionId|vacancyId)$/i.test(key));
            if ((jobPath || jobParameter) && title.length > 2 && title.length < 240) {
                candidates.set(target.href, matchesKeyword(title, keyword));
            }
            if (!jobPath && !jobParameter && isJobBoard(target.href) &&
                /search.*jobs|view.*jobs|current.*openings|job.*openings/i.test(title)) {
                schedule(searchUrl({ url: target.href }, keyword));
            }
        });
    }
    const detailUrls = [...candidates].filter(([url]) => !visited.has(url))
        .sort((first, second) => Number(second[1]) - Number(first[1]))
        .slice(0, MAX_DETAIL_PAGES).map(candidate => candidate[0]);
    for (let offset = 0; offset < detailUrls.length && !signal.aborted; offset += 4) {
        await Promise.all(detailUrls.slice(offset, offset + 4).map(async url => {
            try {
                const detail = await loadPage(url);
                detailPages++;
                jobs.push(...extractJobs(detail.text, detail.url, keyword));
            } catch { failedRequests++; }
        }));
    }
    const limitsReached = queue.length > 0 || candidates.size > MAX_DETAIL_PAGES || signal.aborted;
    return { jobs, status: 'partial', coverage: { listingPages, detailPages, failedRequests, limitsReached },
        message: listingPages + ' listing pages and ' + detailPages + ' job pages checked. ' +
            (failedRequests ? failedRequests + ' page requests failed. ' : '') +
            (limitsReached ? 'A scan limit or timeout was reached. ' : '') +
            (jobs.length ? '' : 'No verified matches retrieved. ') +
            'Coverage remains partial; dynamic, login-only or undiscovered listings may be missing.' };
}

async function searchSource(source, keyword, parentSignal, connectors = {}) {
    const terms = parseKeywords(keyword);
    const signal = AbortSignal.any([parentSignal, AbortSignal.timeout(PORTAL_LIMIT * Math.min(Math.max(terms.length, 1), 3))]);
    try {
        const connector = /\.myworkdayjobs\.com$/.test(new URL(source.url).hostname) ?
            (connectors.workday || workdaySearch) : (connectors.generic || genericSearch);
        const results = [];
        const unique = new Map();
        const context = { pages: new Map() };
        for (const term of terms) {
            try {
                if (signal.aborted) throw new Error('Search cancelled');
                const result = await connector(source, term, signal, context);
                results.push(result);
                for (const job of result.jobs) {
                    if (safeUrl(job.url)) unique.set(job.url, { ...job, company: source.company });
                }
            } catch {
                results.push({ status: 'unavailable', jobs: [], message: signal.aborted ?
                    'Portal timed out or search was cancelled.' :
                    'Portal could not be read. It may block automated access or be temporarily unavailable.' });
            }
        }
        const unavailable = results.filter(result => result.status === 'unavailable').length;
        const status = unavailable === results.length ? 'unavailable' :
            results.some(result => result.status !== 'searched') ? 'partial' : 'searched';
        const message = terms.length === 1 ? results[0].message :
            terms.length + ' keyword searches attempted; ' + unavailable + ' unavailable. ' +
            (status === 'searched' ? 'Live searches completed with saved portal filters.' :
                'Coverage is incomplete; other matching vacancies may exist.');
        return { ...source, status, message, jobs: [...unique.values()] };
    } catch (error) {
        return { ...source, jobs: [], status: 'unavailable', message:
            signal.aborted ? 'Portal timed out or search was cancelled.' :
                'Portal could not be read. It may block automated access or be temporarily unavailable.' };
    }
}

function createServer(options = {}) {
    const config = { ...runtimeConfig(), ...options };
    const publicHost = config.publicOrigin ? new URL(config.publicOrigin).host : '';
    const recentStarts = [];
    let activeSearches = 0;
    return http.createServer({ requestTimeout: 15000, headersTimeout: 10000, maxHeaderSize: 8192 }, async (req, res) => {
        const host = (req.headers.host || '').toLowerCase();
        if (!(publicHost ? host === publicHost || host === publicHost + ':443' : /^localhost:\d+$|^127\.0\.0\.1:\d+$/.test(host))) {
            res.writeHead(403).end('Host is not allowed');
            return;
        }
        let url;
        try { url = new URL(req.url, 'http://localhost'); }
        catch { res.writeHead(400).end('Invalid request URL'); return; }
        const origin = req.headers.origin;
        const expectedOrigin = config.publicOrigin || 'http://' + host;
        if ((origin && origin !== expectedOrigin) ||
            (url.pathname === '/api/search' && req.headers['sec-fetch-site'] === 'cross-site')) {
            res.writeHead(403).end('Open the page at its configured address');
            return;
        }
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Referrer-Policy', 'no-referrer');
        if (req.method !== 'GET' && !(req.method === 'POST' && url.pathname === '/api/search')) {
            res.writeHead(405, { Allow: url.pathname === '/api/search' ? 'GET, POST' : 'GET' }).end();
        } else if (url.pathname === '/' || url.pathname === '/job_hub.html') {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            fs.createReadStream(pagePath).pipe(res);
        } else if (url.pathname === '/healthz') {
            res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }).end(JSON.stringify({ status: 'ok' }));
        } else if (url.pathname === '/lucide.js') {
            res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' });
            fs.createReadStream(path.join(path.dirname(require.resolve('lucide/package.json')), 'dist/umd/lucide.js')).pipe(res);
        } else if (url.pathname === '/api/search') {
            let payload;
            try { payload = req.method === 'POST' ? await readJsonBody(req) : null; }
            catch (error) { res.writeHead(400).end(error.message); return; }
            const keywordValue = req.method === 'POST' ? payload?.keyword : url.searchParams.get('q');
            const keyword = typeof keywordValue === 'string' ? keywordValue.trim() : '';
            if (!keyword || keyword.length > 120) {
                res.writeHead(400).end('Enter a keyword between 1 and 120 characters.');
                return;
            }
            try {
                if (!parseKeywords(keyword).length) throw new Error('Enter at least one non-empty keyword.');
            } catch (error) { res.writeHead(400).end(error.message); return; }
            let sources;
            try { sources = req.method === 'POST' ? validateSources(payload.sources) : loadSources(); } catch (error) {
                res.writeHead(req.method === 'POST' ? 400 : 500).end(error.message);
                return;
            }
            const now = Date.now();
            while (recentStarts.length && recentStarts[0] <= now - 60000) recentStarts.shift();
            if (activeSearches >= config.maxConcurrentSearches || recentStarts.length >= config.searchStartsPerMinute) {
                res.writeHead(429, { 'Content-Type': 'application/json', 'Retry-After': '15', 'Cache-Control': 'no-store' })
                    .end(JSON.stringify({ message: 'Search capacity is busy. Please wait a moment and try again.' }));
                return;
            }
            activeSearches++;
            recentStarts.push(now);
            let released = false;
            const release = () => { if (!released) { activeSearches--; released = true; } };
            const controller = new AbortController();
            let heartbeat;
            res.on('close', () => { controller.abort(); clearInterval(heartbeat); release(); });
            res.writeHead(200, { 'Content-Type': 'application/x-ndjson; charset=utf-8', 'Cache-Control': 'no-store' });
            const send = event => {
                if (res.destroyed) return;
                if (res.writableLength > 1048576) { controller.abort(); res.destroy(); return; }
                res.write(JSON.stringify(event) + '\n');
            };
            try {
                send({ type: 'start', total: sources.length });
                heartbeat = setInterval(() => send({ type: 'heartbeat' }), 15000);
                heartbeat.unref();
                let nextIndex = 0;
                await Promise.all(Array.from({ length: Math.min(config.parallelPortals, sources.length) }, async () => {
                    while (nextIndex < sources.length && !controller.signal.aborted) {
                        const source = sources[nextIndex++];
                        const result = await searchSource(source, keyword, controller.signal);
                        send({ type: 'source', ...result });
                    }
                }));
                send({ type: 'done', checkedAt: new Date().toISOString() });
                res.end();
            } finally {
                clearInterval(heartbeat);
                release();
            }
        } else {
            res.writeHead(404).end('Not found');
        }
    });
}

if (require.main === module) {
    const config = runtimeConfig();
    const server = createServer(config);
    const listen = port => {
        const onError = error => {
            if (error.code === 'EADDRINUSE' && config.allowPortFallback && port < 8775) listen(port + 1);
            else { console.error(error.message); process.exitCode = 1; }
        };
        server.once('error', onError);
        server.listen(port, config.host, () => {
            server.removeListener('error', onError);
            console.log('Job hub ready: ' + (config.publicOrigin || 'http://127.0.0.1:' + port));
        });
    };
    listen(config.port);
}

module.exports = { matchesKeyword, safeUrl, loadSources, searchUrl, extractJobs, searchSource, createServer, validateSources, publicPortalUrl, isPublicAddress, parseKeywords, runtimeConfig };