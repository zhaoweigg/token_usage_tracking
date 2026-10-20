import Foundation

enum ProviderScripts {
    // Executed only in the account's isolated WebKit profile on the provider's
    // exact HTTPS origin. Access tokens never leave this isolated JS world.
    static func capture(for provider: AIProvider) -> String {
        common + (provider == .claude ? claude : chatGPT) + "\nconst result = await capture().catch(normalizeError); return JSON.stringify({...result, diagnostic});"
    }

    private static let common = #"""
    // Only fixed operation names and status/format are exported for diagnosis.
    // Never export URLs, headers, response bodies, cookies, or exception messages.
    const diagnostic = {step:'page', status:0, format:'unknown'};
    async function getJSON(path, headers = {}, step = 'usage') {
        Object.assign(diagnostic, {step, status:0, format:'unknown'});
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 12000);
        try {
            const response = await fetch(path, {
                method: 'GET', credentials: 'include', cache: 'no-store',
                redirect: 'error', headers: { 'Accept': 'application/json', ...headers },
                signal: controller.signal
            });
            diagnostic.status = response.status;
            if (response.status === 401) throw {code:'signInRequired'};
            if (response.status === 429) {
                const seconds = Number(response.headers.get('Retry-After'));
                throw {code:'rateLimited', retryAfter:Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 3600) : 300};
            }
            const text = await response.text();
            if (text.length > 2000000) throw {code:'invalidResponse'};
            let body;
            try { body = JSON.parse(text); diagnostic.format = 'json'; }
            catch (_) {
                diagnostic.format = /<html|<!doctype html/i.test(text) ? 'html' : 'text';
                if (/just a moment|cf-chl|challenge-platform|verify you are human/i.test(text)) throw {code:'challenge'};
                throw {code:response.status === 403 ? 'forbidden' : 'invalidResponse'};
            }
            if (response.status === 403) throw {code:'forbidden'};
            if (!response.ok) throw {code:'http', status:response.status};
            return body;
        } catch (error) {
            if (error.name === 'AbortError') throw {code:'timeout'};
            throw error;
        } finally { clearTimeout(timer); }
    }
    function normalizeError(error) {
        return {error:error.code || 'network', status:error.status || 0, retryAfter:error.retryAfter || 300};
    }
    function text(value) { return typeof value === 'string' && value.trim() && value.length <= 256 ? value : null; }
    """#

    private static let claude = #"""
    async function capture() {
        if (location.origin !== 'https://claude.ai') throw {code:'signInRequired'};
        const user = claudeIdentity(await getJSON('/api/account', {}, 'identity'));
        const userID = user.id;
        const organizations = await getJSON('/api/organizations', {}, 'workspaces');
        const rows = Array.isArray(organizations) ? organizations : organizations.organizations;
        if (!Array.isArray(rows)) throw {code:'invalidResponse'};
        const workspaces = rows.map(org => ({
            id:text(org.uuid) || text(org.id), name:text(org.name) || 'Claude workspace',
            plan:text(org.plan_name) || text(org.rate_limit_tier)
        })).filter(org => org.id);
        const chosen = workspaceID ? workspaces.find(org => org.id === workspaceID) : workspaces.length === 1 ? workspaces[0] : null;
        if (workspaceID && !chosen) throw {code:'wrongAccount'};
        const result = {identity:user, workspaces};
        if (!chosen) return result;
        const usage = await getJSON('/api/organizations/' + encodeURIComponent(chosen.id) + '/usage', {}, 'usage');
        const afterUser = claudeIdentity(await getJSON('/api/account', {}, 'verification'));
        if (afterUser.id !== userID) throw {code:'wrongAccount'};
        diagnostic.step = 'usage';
        return {...result, workspaceID:chosen.id, usage};
    }
    function claudeIdentity(account) {
        const user = account?.account || account;
        const email = text(user?.email_address) || text(user?.email);
        // Some account responses expose email and memberships without a UUID.
        // Use the authenticated response's email, never an entered alias or org ID.
        const id = text(user?.uuid) || text(user?.id) || (email ? 'claude-email:' + email.trim().toLowerCase() : null);
        if (!id || id.length > 256) throw {code:'invalidResponse'};
        return {id, email};
    }
    """#

    private static let chatGPT = #"""
    async function capture() {
        if (location.origin !== 'https://chatgpt.com') throw {code:'signInRequired'};
        const session = await getJSON('/api/auth/session', {}, 'session');
        const userID = text(session.user?.id);
        const token = textToken(session.accessToken);
        if (!userID || !token) throw {code:'signInRequired'};
        const headers = {'Authorization':'Bearer ' + token};
        let workspaces;
        try {
            const listing = await getJSON('/backend-api/accounts/check/v4-2023-04-27', headers, 'workspaces');
            if (!listing.accounts || typeof listing.accounts !== 'object') throw {code:'invalidResponse'};
            workspaces = Object.entries(listing.accounts).map(([key, item]) => {
                const account = item.account || item;
                return {id:text(account.account_id) || text(account.id) || text(key),
                    name:text(account.name) || (account.is_personal ? 'Personal workspace' : 'ChatGPT workspace'),
                    plan:text(account.plan_type) || text(item.entitlement?.subscription_plan)};
            }).filter(item => item.id && item.id !== 'default');
        } catch (error) {
            // A verified server-issued session can identify its default workspace
            // when account discovery is unavailable; never guess a workspace ID.
            if (error.status !== 404) throw error;
            let claims;
            try {
                const encoded = token.split('.')[1].replace(/-/g,'+').replace(/_/g,'/');
                claims = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(encoded), c => c.charCodeAt(0))));
            } catch (_) { throw {code:'unavailable'}; }
            const auth = claims['https://api.openai.com/auth'] || {};
            const id = text(auth.chatgpt_account_id);
            if (!id) throw {code:'unavailable'};
            workspaces = [{id, name:'ChatGPT workspace', plan:text(auth.chatgpt_plan_type)}];
        }
        const chosen = workspaceID ? workspaces.find(item => item.id === workspaceID) : workspaces.length === 1 ? workspaces[0] : null;
        if (workspaceID && !chosen) throw {code:'wrongAccount'};
        const result = {identity:{id:userID, email:text(session.user.email)}, workspaces};
        if (!chosen) return result;
        const usage = await getJSON('/backend-api/wham/usage', {...headers, 'ChatGPT-Account-Id':chosen.id});
        if (usage.account_id && usage.account_id !== chosen.id) throw {code:'wrongAccount'};
        const after = await getJSON('/api/auth/session', {}, 'verification');
        if (text(after.user?.id) !== userID) throw {code:'wrongAccount'};
        diagnostic.step = 'usage';
        return {...result, workspaceID:chosen.id, usage};
    }
    function textToken(value) { return typeof value === 'string' && value.length < 32768 ? value : null; }
    """#
}
