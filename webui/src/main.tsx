import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  createRootRoute,
  createRoute,
  createRouter,
  RouterProvider,
  redirect,
} from "@tanstack/react-router";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { EventStream } from "./api/events";
import { AppShell } from "./components/AppShell";
import { ServerPage } from "./features/server/ServerPage";
import { setSSEConnected } from "./stores/connection";
import "./styles/base.css";

const queryClient = new QueryClient();
const events = new EventStream(queryClient);
events.onConnectionChange = setSSEConnected;
events.start();

const rootRoute = createRootRoute({ component: AppShell });

function placeholder(title: string) {
  return function Placeholder() {
    return (
      <div style={{ padding: "var(--s6)", color: "var(--text-secondary)" }}>
        <h1 style={{ fontSize: "var(--text-title)", color: "var(--text)" }}>{title}</h1>
        <p>This section is coming in a later phase.</p>
      </div>
    );
  };
}

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  beforeLoad: () => {
    throw redirect({ to: "/server" });
  },
});

const routes = [
  indexRoute,
  createRoute({ getParentRoute: () => rootRoute, path: "/server", component: ServerPage }),
  createRoute({
    getParentRoute: () => rootRoute,
    path: "/production/$mode",
    component: placeholder("Production"),
  }),
  createRoute({
    getParentRoute: () => rootRoute,
    path: "/library",
    component: placeholder("Library"),
  }),
  createRoute({
    getParentRoute: () => rootRoute,
    path: "/quality",
    component: placeholder("ReadAloud Quality"),
  }),
  createRoute({
    getParentRoute: () => rootRoute,
    path: "/settings/$scope",
    component: placeholder("Settings"),
  }),
];

const router = createRouter({
  routeTree: rootRoute.addChildren(routes),
  basepath: "/ui",
});

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router;
  }
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
