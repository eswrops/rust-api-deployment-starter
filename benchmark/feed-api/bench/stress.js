/**
 * Local stress profile for tuning experiments. The upstream bench/load.js
 * models real user think time (5-15 s idle), which never saturates the
 * server; this profile removes the idle time so pool and pragma choices can
 * be compared under load. Measurement tooling only — the scored submission
 * is measured with the upstream load.js untouched.
 *
 *   k6 run -e VUS=200 -e DURATION=60s -e TOKENS=seed/tokens.json bench/stress.js
 *
 * Mix per iteration: GET /feed, GET /posts/:id (from the feed), 20% like,
 * 5% create, 50 ms pause. Same pass thresholds as the upstream test.
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:3100';
const VUS = Number(__ENV.VUS || 100);
const DURATION = __ENV.DURATION || '60s';
const RAMP_UP = __ENV.RAMP_UP || '15s';
const tokens = new SharedArray('tokens', () => JSON.parse(open(__ENV.TOKENS || '../seed/tokens.json')));

export const options = {
  scenarios: {
    users: {
      executor: 'ramping-vus',
      stages: [
        { duration: RAMP_UP, target: VUS },
        { duration: DURATION, target: VUS },
        { duration: '10s', target: 0 },
      ],
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const user = tokens[(__VU - 1) % tokens.length];
  const auth = { headers: { Authorization: `Bearer ${user.token}`, 'Content-Type': 'application/json' } };

  const feed = http.get(`${BASE_URL}/feed`, { tags: { name: 'GET /feed' } });
  if (!check(feed, { 'feed 200': (r) => r.status === 200 })) return;
  const posts = feed.json('posts');
  if (!posts || posts.length === 0) return;
  const post = posts[Math.floor(Math.random() * posts.length)];

  check(http.get(`${BASE_URL}/posts/${post.id}`, { tags: { name: 'GET /posts/:id' } }), {
    'post 200': (r) => r.status === 200,
  });

  if (Math.random() < 0.2) {
    check(http.post(`${BASE_URL}/posts/${post.id}/like`, null, { ...auth, tags: { name: 'POST /posts/:id/like' } }), {
      'like 200/201': (r) => r.status === 200 || r.status === 201,
    });
  }
  if (Math.random() < 0.05) {
    const body = JSON.stringify({ body: `${user.username} stress post ${Date.now()} (VU ${__VU})` });
    check(http.post(`${BASE_URL}/posts`, body, { ...auth, tags: { name: 'POST /posts' } }), {
      'create 201': (r) => r.status === 201,
    });
  }
  sleep(0.05);
}
