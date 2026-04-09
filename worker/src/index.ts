/**
 * Clicky Proxy Worker
 *
 * Proxies requests to OpenAI APIs so the app never ships with raw API keys.
 * Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   POST /responses             → OpenAI Responses API
 *   POST /speech                → OpenAI Audio Speech API
 *   POST /transcription-session → OpenAI Realtime transcription session API
 */

interface Env {
  OPENAI_API_KEY: string;
  OPENAI_TTS_MODEL?: string;
  OPENAI_TTS_VOICE?: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    try {
      if (url.pathname === "/responses") {
        return await handleResponses(request, env);
      }

      if (url.pathname === "/speech") {
        return await handleSpeech(request, env);
      }

      if (url.pathname === "/transcription-session") {
        return await handleTranscriptionSession(request, env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return new Response(
        JSON.stringify({ error: String(error) }),
        { status: 500, headers: { "content-type": "application/json" } }
      );
    }

    return new Response("Not found", { status: 404 });
  },
};

async function handleResponses(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
      Accept: request.headers.get("accept") || "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/responses] OpenAI Responses API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "application/json",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscriptionSession(request: Request, env: Env): Promise<Response> {
  const body = await request.text();

  const response = await fetch("https://api.openai.com/v1/realtime/transcription_sessions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
    },
    body,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcription-session] OpenAI Realtime session error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: { "content-type": "application/json" },
  });
}

async function handleSpeech(request: Request, env: Env): Promise<Response> {
  const requestBody = await request.json<Record<string, unknown>>();
  const speechRequestBody = {
    model: env.OPENAI_TTS_MODEL || "gpt-4o-mini-tts",
    voice: env.OPENAI_TTS_VOICE || "cedar",
    format: "mp3",
    ...requestBody,
  };

  const response = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      "content-type": "application/json",
      accept: "audio/mpeg",
    },
    body: JSON.stringify(speechRequestBody),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/speech] OpenAI speech API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
