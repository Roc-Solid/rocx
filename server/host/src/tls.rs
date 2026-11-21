//! TLS for what the host connects to (a `Tcp` connection, Postgres, an HTTP server): rustls, with
//! ring, checking certificates against the web's certificate authorities (webpki-roots).

use std::sync::{Arc, OnceLock};

fn config() -> rustls::ClientConfig {
    let roots = rustls::RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .expect("rustls's default protocol versions")
        .with_root_certificates(roots)
        .with_no_client_auth()
}

/// The client configuration every TLS connection uses.
pub fn client_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG.get_or_init(|| Arc::new(config())).clone()
}

/// The same, saying it speaks HTTP/1.1 (ALPN): `Http`'s requests (`client`).
pub fn http_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    CONFIG
        .get_or_init(|| {
            let mut config = config();
            config.alpn_protocols = vec![b"http/1.1".to_vec()];
            Arc::new(config)
        })
        .clone()
}
