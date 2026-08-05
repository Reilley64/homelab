import { type NextRequest, NextResponse } from "next/server";
import { getToken } from "next-auth/jwt";
import { isDevelopmentEnvironment } from "./lib/constants";

export async function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;

  if (pathname.startsWith("/ping")) {
    return new Response("pong", { status: 200 });
  }

  if (pathname.startsWith("/api/auth")) {
    return NextResponse.next();
  }

  const token = await getToken({
    req: request,
    secret: process.env.AUTH_SECRET,
    secureCookie: !isDevelopmentEnvironment,
  });

  const base = process.env.NEXT_PUBLIC_BASE_PATH ?? "";

  // The login page is the one route an anonymous visitor must be able to reach;
  // sending them to /login from here would redirect it to itself forever.
  if (pathname === "/login") {
    return token
      ? NextResponse.redirect(new URL(`${base}/`, request.url))
      : NextResponse.next();
  }

  if (!token) {
    // API callers get a status they can act on. Redirecting them to an HTML
    // login page instead means an expired session shows up as a parse error
    // mid-stream rather than a 401.
    if (pathname.startsWith("/api/")) {
      return new NextResponse(null, { status: 401 });
    }

    const redirectUrl = encodeURIComponent(new URL(request.url).pathname);

    return NextResponse.redirect(
      new URL(`${base}/login?callbackUrl=${redirectUrl}`, request.url)
    );
  }

  return NextResponse.next();
}

export const config = {
  matcher: [
    "/",
    "/chat/:id",
    "/api/:path*",
    "/login",

    "/((?!_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt).*)",
  ],
};
