namespace SHKRIntegration.Extensions;

public sealed class SapCreateReplyException(string message, Exception? innerException = null)
    : Exception(message, innerException);

public static class SapCreateOutcomeExtensions
{
    public static bool IsSapCreateOutcomeUnknown(this Exception exception) => exception switch
    {
        SapCreateReplyException => true,
        OperationCanceledException => true,
        HttpRequestException { HttpRequestError: HttpRequestError.ResponseEnded or HttpRequestError.InvalidResponse } => true,
        _ => false,
    };

    public static string ToSapCreateFailureMessage(this Exception exception, string document, string sapCheck)
    {
        if (exception is OperationCanceledException)
        {
            return $"SAP did not answer within {(int)ShkrSapIntegrationExtensions.NoRetryTimeout.TotalSeconds} s. "
                + $"The {document} may have been created in SAP. Check in SAP ({sapCheck}) before resubmitting.";
        }

        if (exception.IsSapCreateOutcomeUnknown())
        {
            return $"SAP did not send a complete reply with the {document} number. "
                + $"The {document} may have been created in SAP. Check in SAP ({sapCheck}) before resubmitting.";
        }

        return exception.Message;
    }
}
