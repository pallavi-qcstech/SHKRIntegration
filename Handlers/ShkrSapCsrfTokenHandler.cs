using System.Net.Http.Headers;

namespace SHKRIntegration.Handlers;


/// Translates the CSRF-token handshake used throughout the Postman collection's
/// pre-request script into a DelegatingHandler: SAP OData Gateway services reject
/// non-GET requests unless an x-csrf-token header (obtained from a prior GET) is
/// attached. This runs automatically for every request made through the named
/// "ShkrSap" HttpClient - no per-call setup required.
///
/// Requires the owning HttpClient's primary handler to use a shared CookieContainer
/// (see Program.cs) so the session cookie from the token-fetch GET carries over to
/// the actual request, matching Postman's per-request cookie jar behavior.

public sealed class ShkrSapCsrfTokenHandler : DelegatingHandler
{
    private const string CsrfHeaderName = "x-csrf-token";

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        if (request.Method != HttpMethod.Get && !request.Headers.Contains(CsrfHeaderName))
        {
            var tokenFetchRequest = new HttpRequestMessage(HttpMethod.Get, BuildTokenFetchUri(request));
            tokenFetchRequest.Headers.TryAddWithoutValidation(CsrfHeaderName, "fetch");

            // request.Headers already carries the HttpClient's DefaultRequestHeaders (Authorization,
            // Accept - see ShkrSapIntegrationExtensions.ConfigureShkrSapClient), merged in by HttpClient itself
            // before this handler runs. tokenFetchRequest is a brand-new HttpRequestMessage sent
            // directly via base.SendAsync below, bypassing that merge - so without copying it here,
            // the token-fetch GET goes out unauthenticated and SAP returns 401, leaving no token to
            // attach and causing the real request below to fail CSRF validation (403).
            if (request.Headers.Authorization is not null)
            {
                tokenFetchRequest.Headers.Authorization = request.Headers.Authorization;
            }

            using var tokenFetchResponse = await base.SendAsync(tokenFetchRequest, cancellationToken);

            if (tokenFetchResponse.Headers.TryGetValues(CsrfHeaderName, out var tokenValues))
            {
                var token = tokenValues.FirstOrDefault();
                if (!string.IsNullOrEmpty(token))
                {
                    request.Headers.TryAddWithoutValidation(CsrfHeaderName, token);
                }
            }
        }

        return await base.SendAsync(request, cancellationToken);
    }


    /// Same intent as the Postman script's "for POST, append ?$top=1 to quickly get
    /// a token" - but builds the query string correctly instead of blindly
    /// concatenating "?$top=1" onto a URL that may already have a query string
    /// (the original script did this; SAP tolerated the resulting malformed URL
    /// in testing, but a real client should not rely on that).

    private static Uri BuildTokenFetchUri(HttpRequestMessage request)
    {
        var uri = request.RequestUri!;
        if (request.Method != HttpMethod.Post)
        {
            return uri;
        }

        var builder = new UriBuilder(uri);
        var separator = string.IsNullOrEmpty(builder.Query) || builder.Query == "?" ? "" : "&";
        builder.Query = builder.Query.TrimStart('?') + separator + "$top=1";
        return builder.Uri;
    }
}
