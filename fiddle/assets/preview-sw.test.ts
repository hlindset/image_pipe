import { afterEach, beforeEach, expect, it, vi } from "vitest";

type PreviewFetchEvent = {
  request: Request;
  clientId: string;
  respondWith: (response: Promise<Response>) => void;
  waitUntil: (completion: Promise<void>) => void;
};

let dispatch: (event: PreviewFetchEvent) => void;
const postMessage = vi.fn();

beforeEach(async () => {
  vi.resetModules();
  postMessage.mockReset();
  vi.stubGlobal("self", {
    addEventListener: (type: string, listener: (event: PreviewFetchEvent) => void) => {
      if (type === "fetch") dispatch = listener;
    },
    clients: { get: async () => ({ postMessage }) },
  });
  await import("./preview-sw");
});

afterEach(() => vi.unstubAllGlobals());

it("extends metadata lifetime without delaying the original streamed response", async () => {
  const body = Promise.withResolvers<Uint8Array>();
  const response = new Response(
    new ReadableStream({
      async start(controller) {
        controller.enqueue(await body.promise);
        controller.close();
      },
    }),
    { headers: { "content-type": "image/jpeg", "x-imagepipe-cache": "miss" } },
  );
  const fetcher = vi.fn().mockResolvedValue(response);
  vi.stubGlobal("fetch", fetcher);
  const request = new Request("http://localhost:4000/image/w=10/src/images/dog.jpg", {
    headers: { accept: "image/avif,image/webp" },
  });
  const respondWith = vi.fn();
  const waitUntil = vi.fn();
  dispatch({ request, clientId: "preview", respondWith, waitUntil });

  expect(await respondWith.mock.calls[0]?.[0]).toBe(response);
  expect(fetcher).toHaveBeenCalledWith(request);
  expect(waitUntil).toHaveBeenCalledOnce();
  expect(postMessage).not.toHaveBeenCalled();

  body.resolve(new TextEncoder().encode("image bytes"));
  await waitUntil.mock.calls[0]?.[0];
  expect(postMessage).toHaveBeenCalledWith(
    expect.objectContaining({
      url: request.url,
      accept: "image/avif,image/webp",
      bytes: 11,
      debugHeaders: { "x-imagepipe-cache": "miss" },
    }),
  );
  expect(await response.text()).toBe("image bytes");
});

it("keeps metadata read failures out of response delivery", async () => {
  const response = new Response("image bytes");
  const clone = response.clone();
  vi.spyOn(clone, "arrayBuffer").mockRejectedValue(new Error("clone interrupted"));
  vi.spyOn(response, "clone").mockReturnValue(clone);
  vi.stubGlobal("fetch", vi.fn().mockResolvedValue(response));
  const respondWith = vi.fn();
  const waitUntil = vi.fn();
  dispatch({
    request: new Request("http://localhost:4000/image/src/images/dog.jpg"),
    clientId: "preview",
    respondWith,
    waitUntil,
  });

  expect(await respondWith.mock.calls[0]?.[0]).toBe(response);
  expect(waitUntil).toHaveBeenCalledOnce();
  await expect(waitUntil.mock.calls[0]?.[0]).resolves.toBeUndefined();
  expect(postMessage).not.toHaveBeenCalled();
});
