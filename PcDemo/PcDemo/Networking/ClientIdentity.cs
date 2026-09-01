// LocalSend 官方协议 HTTPS 模式 = mTLS：TLS 握手时客户端必须出示自签名客户端证书，
// 服务端（手机 App）只验证证书结构有效（"We trust any certificate that is valid"），
// 并把证书 SHA-256 指纹作为请求方身份。若客户端不出示证书 → 握手直接被服务端断连。
// 官方证书规格（packages/core/src/crypto/cert.rs generate_self_signed）：
//   RSA-2048 + CN=LocalSend User + 无 SAN + 自签，同一证书兼作服务器/客户端证书。
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace PcDemo.Networking;

internal static class ClientIdentity
{
    private const string CertFileName = "client-identity.pfx";
    private const string CertSubjectCn = "LocalSend User";

    /// <summary>
    /// 计算证书的设备指纹：SHA-256(DER) 大写 hex（与官方 fingerprint_from_cert_der 一致）。
    /// 官方协议要求：请求 body 里的 info.fingerprint 必须等于 mTLS 客户端证书指纹，
    /// 否则对方（HTTPS-only）会静默丢弃接收事件，导致 prepare-upload 永久挂起。
    /// </summary>
    public static string ComputeFingerprint(X509Certificate2 cert)
    {
        var der = cert.Export(X509ContentType.Cert);
        return Convert.ToHexString(SHA256.HashData(der));
    }

    /// <summary>
    /// 获取（或首次生成）我们的 mTLS 客户端证书。失败时返回 null（HTTP 模式不受影响）。
    /// </summary>
    public static X509Certificate2? GetOrCreate()
    {
        try
        {
            var path = System.IO.Path.Combine(Helpers.PathHelper.AppDataDir, CertFileName);
            if (File.Exists(path))
            {
                var cert = new X509Certificate2(path);
                App.LogDiag($"[TLS] mTLS 客户端证书已加载: {cert.Subject} (thumb={cert.Thumbprint})");
                return cert;
            }

            // 与官方 generate_self_signed 对齐：RSA-2048 + CN=LocalSend User + 自签。
            // CN 与官方一致还有个好处：rustls 服务端的 root_hint_subjects 即服务器证书
            // subject（CN=LocalSend User），Windows SChannel 的 issuer 过滤能直接匹配。
            using var rsa = RSA.Create(2048);
            var req = new CertificateRequest($"CN={CertSubjectCn}", rsa,
                HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            using var publicCert = req.CreateSelfSigned(
                DateTimeOffset.UtcNow.AddDays(-1),
                DateTimeOffset.UtcNow.AddYears(100));

            // PFX（无密码）持久化，下次启动复用同一身份
            var pfx = publicCert.Export(X509ContentType.Pkcs12);
            File.WriteAllBytes(path, pfx);

            var loaded = new X509Certificate2(path);
            App.LogDiag($"[TLS] 已生成新的 mTLS 客户端证书: {loaded.Subject} (thumb={loaded.Thumbprint})");
            return loaded;
        }
        catch (Exception ex)
        {
            App.LogDiag($"[TLS] mTLS 客户端证书生成/加载失败（HTTP 模式不受影响）: {ex.GetType().Name}: {ex.Message}");
            return null;
        }
    }
}
