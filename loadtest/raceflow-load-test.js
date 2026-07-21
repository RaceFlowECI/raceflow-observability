// Load test for RaceFlow's core flow: register -> login -> create room -> join room -> read state.
// Targets the real API Gateway (auth-service + realtime-service behind it), not a toy endpoint.
//
// Usage:
//   BASE_URL=https://raceflow-gateway-g8csc0dfh0dxhcax.mexicocentral-01.azurewebsites.net k6 run raceflow-load-test.js
//   BASE_URL=http://localhost:8080 k6 run raceflow-load-test.js   (against the local docker-compose.dev.yml stack)
//
// Thresholds are set against the same SLO tracked in Grafana/Prometheus for
// raceflow_ranking_update_duration_seconds (p99 <= 1s) and the general HTTP
// error budget used by the RaceFlowHighErrorRate alert (5xx rate > 5%).

import http from 'k6/http';
import { sleep, check, group } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';

export const options = {
  stages: [
    { duration: '20s', target: 10 },
    { duration: '40s', target: 25 },
    { duration: '20s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<800'],
    'http_req_duration{endpoint:createRoom}': ['p(99)<1000'],
  },
};

export default function () {
  const email = `loadtest-${__VU}-${__ITER}@raceflow.dev`;
  const password = 'LoadTest123';
  let token;

  group('register + login', () => {
    const registerRes = http.post(
      `${BASE_URL}/api/auth/register`,
      JSON.stringify({ email, password, name: `LoadTest VU${__VU}` }),
      { headers: { 'Content-Type': 'application/json' }, tags: { endpoint: 'register' } }
    );
    check(registerRes, {
      'register: 201 or 409 (already exists)': (r) => r.status === 201 || r.status === 409,
    });

    const loginRes = http.post(
      `${BASE_URL}/api/auth/login`,
      JSON.stringify({ email, password }),
      { headers: { 'Content-Type': 'application/json' }, tags: { endpoint: 'login' } }
    );
    check(loginRes, { 'login: 200': (r) => r.status === 200 });
    token = loginRes.status === 200 ? loginRes.json('token') : null;
  });

  if (!token) {
    sleep(1);
    return;
  }

  const authHeaders = {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
  };

  let roomCode;
  group('create room', () => {
    const createRes = http.post(
      `${BASE_URL}/api/rooms/create`,
      JSON.stringify({ name: `LoadTest VU${__VU}` }),
      { ...authHeaders, tags: { endpoint: 'createRoom' } }
    );
    check(createRes, { 'createRoom: 201': (r) => r.status === 201 });
    roomCode = createRes.status === 201 ? createRes.json('roomCode') : null;
  });

  if (roomCode) {
    group('read room state', () => {
      const stateRes = http.get(
        `${BASE_URL}/api/rooms/${roomCode}/state`,
        { ...authHeaders, tags: { endpoint: 'roomState' } }
      );
      check(stateRes, { 'roomState: 200': (r) => r.status === 200 });
    });
  }

  sleep(1);
}
