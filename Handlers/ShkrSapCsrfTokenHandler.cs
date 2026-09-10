using System.Net.Http.Headers;

namespace SHKRIntegration.Handlers;



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
