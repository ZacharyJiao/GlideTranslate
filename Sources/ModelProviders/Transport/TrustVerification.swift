import Dispatch
import Network
import Security

package enum TrustVerification {
    private static let verificationQueue = DispatchQueue(
        label: "GlideTranslate.ProviderTrustVerification"
    )

    package static func evaluate(
        installOriginalHostPolicy: () -> Bool,
        evaluateInstalledPolicy: () -> Bool
    ) -> Bool {
        guard installOriginalHostPolicy() else { return false }
        return evaluateInstalledPolicy()
    }

    package static func install(
        on options: sec_protocol_options_t,
        expectedHost: String
    ) {
        sec_protocol_options_set_verify_block(
            options,
            { _, trust, completion in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let accepted = evaluate(
                    installOriginalHostPolicy: {
                        SecTrustSetPolicies(
                            secTrust,
                            SecPolicyCreateSSL(true, expectedHost as CFString)
                        ) == errSecSuccess
                    },
                    evaluateInstalledPolicy: {
                        var error: CFError?
                        return SecTrustEvaluateWithError(secTrust, &error)
                    }
                )
                completion(accepted)
            },
            verificationQueue
        )
    }
}
