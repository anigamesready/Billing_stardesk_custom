package com.anigamesready.adminandroiddbv0;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.SocketAddress;
import java.net.SocketException;
import java.nio.channels.SocketChannel;
import java.util.Collections;

import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLException;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;

/**
 * Pins the Android DB Gateway TCP connection to known Cloudflare anycast IPv4
 * edges while preserving the original HTTPS hostname, SNI and certificate
 * hostname validation. This factory is only for the fixed Ani Games Gateway.
 */
public final class GatewayPinnedSocketFactory extends SSLSocketFactory {
    public static final String GATEWAY_HOST =
        "ani-games-db-android-stage-gateway.anigamesready.workers.dev";
    private static final int HTTPS_PORT = 443;
    private static final int CONNECT_TIMEOUT_MS = 10000;
    private static final String[] CLOUDFLARE_IPV4 = {"104.18.13.15", "104.18.12.15"};
    private final SSLSocketFactory delegate;

    public GatewayPinnedSocketFactory() {
        this.delegate = (SSLSocketFactory) SSLSocketFactory.getDefault();
    }

    public static boolean isGatewayHost(String host) {
        return host != null && GATEWAY_HOST.equalsIgnoreCase(host.trim());
    }

    public static String[] pinnedIpv4Addresses() {
        return CLOUDFLARE_IPV4.clone();
    }

    public static boolean isPinnedIpv4Address(InetAddress address) {
        if (address == null) return false;
        String value = address.getHostAddress();
        for (String approved : CLOUDFLARE_IPV4) {
            if (approved.equals(value)) return true;
        }
        return false;
    }

    private static InetAddress addressFor(String value) throws IOException {
        String[] parts = value.split("\\.");
        if (parts.length != 4) throw new IOException("CLOUDFLARE_PIN_INVALID");
        byte[] bytes = new byte[4];
        for (int i = 0; i < 4; i++) {
            int octet;
            try { octet = Integer.parseInt(parts[i]); }
            catch (NumberFormatException ex) { throw new IOException("CLOUDFLARE_PIN_INVALID", ex); }
            if (octet < 0 || octet > 255) throw new IOException("CLOUDFLARE_PIN_INVALID");
            bytes[i] = (byte) octet;
        }
        return InetAddress.getByAddress(bytes);
    }

    private Socket connectPinned(int port, SocketAddress localBind) throws IOException {
        if (port != HTTPS_PORT) throw new IOException("GATEWAY_HTTPS_PORT_INVALID");
        IOException last = null;
        for (String value : CLOUDFLARE_IPV4) {
            Socket socket = new Socket();
            try {
                if (localBind != null) socket.bind(localBind);
                socket.connect(new InetSocketAddress(addressFor(value), port), CONNECT_TIMEOUT_MS);
                socket.setTcpNoDelay(true);
                return socket;
            } catch (IOException ex) {
                last = ex;
                try { socket.close(); } catch (IOException ignored) {}
            }
        }
        throw new IOException("CLOUDFLARE_PINNED_GATEWAY_CONNECT_FAILED", last);
    }

    private SSLSocket wrapPinned(Socket raw, String host, int port, boolean autoClose) throws IOException {
        if (!isGatewayHost(host) || port != HTTPS_PORT) {
            try { raw.close(); } catch (IOException ignored) {}
            throw new IOException("GATEWAY_TLS_HOST_NOT_ALLOWED");
        }
        if (raw == null || !raw.isConnected() || raw.isClosed()
                || !isPinnedIpv4Address(raw.getInetAddress())) {
            if (raw != null) try { raw.close(); } catch (IOException ignored) {}
            raw = connectPinned(port, null);
        }
        SSLSocket tls = (SSLSocket) delegate.createSocket(raw, GATEWAY_HOST, port, autoClose);
        SSLParameters parameters = tls.getSSLParameters();
        parameters.setServerNames(Collections.singletonList(new SNIHostName(GATEWAY_HOST)));
        tls.setSSLParameters(parameters);
        return tls;
    }

    @Override public String[] getDefaultCipherSuites() {
        return delegate.getDefaultCipherSuites();
    }

    @Override public String[] getSupportedCipherSuites() {
        return delegate.getSupportedCipherSuites();
    }

    /** Android's HTTPS client may request a raw socket first and resolve/connect it later. */
    @Override public Socket createSocket() {
        return new PinnedTcpSocket();
    }

    @Override public Socket createSocket(String host, int port) throws IOException {
        if (!isGatewayHost(host)) throw new IOException("GATEWAY_TLS_HOST_NOT_ALLOWED");
        return wrapPinned(connectPinned(port, null), GATEWAY_HOST, port, true);
    }

    @Override public Socket createSocket(String host, int port, InetAddress local, int localPort)
            throws IOException {
        if (!isGatewayHost(host)) throw new IOException("GATEWAY_TLS_HOST_NOT_ALLOWED");
        SocketAddress bind = local == null ? null : new InetSocketAddress(local, localPort);
        return wrapPinned(connectPinned(port, bind), GATEWAY_HOST, port, true);
    }

    @Override public Socket createSocket(InetAddress host, int port) throws IOException {
        return wrapPinned(connectPinned(port, null), GATEWAY_HOST, port, true);
    }

    @Override public Socket createSocket(InetAddress host, int port, InetAddress local, int localPort)
            throws IOException {
        SocketAddress bind = local == null ? null : new InetSocketAddress(local, localPort);
        return wrapPinned(connectPinned(port, bind), GATEWAY_HOST, port, true);
    }

    @Override public Socket createSocket(Socket socket, String host, int port, boolean autoClose)
            throws IOException {
        if (!isGatewayHost(host)) throw new IOException("GATEWAY_TLS_HOST_NOT_ALLOWED");
        return wrapPinned(socket, GATEWAY_HOST, port, autoClose);
    }

    /** Plain TCP adapter used by Android HttpURLConnection before TLS wrapping. */
    private final class PinnedTcpSocket extends Socket {
        private Socket raw = new Socket();
        private SocketAddress localBind;
        private boolean closed;
        private boolean tcpNoDelay = true;
        private boolean keepAlive;
        private int soTimeout;
        private int sendBufferSize;
        private int receiveBufferSize;
        private int trafficClass = -1;
        private Boolean reuseAddress;

        @Override public void bind(SocketAddress bindpoint) throws IOException {
            if (raw.isConnected()) throw new SocketException("already connected");
            localBind = bindpoint;
            raw.bind(bindpoint);
        }

        @Override public void connect(SocketAddress endpoint) throws IOException {
            connect(endpoint, 0);
        }

        @Override public void connect(SocketAddress endpoint, int timeout) throws IOException {
            if (!(endpoint instanceof InetSocketAddress) || ((InetSocketAddress) endpoint).getPort() != HTTPS_PORT)
                throw new IOException("GATEWAY_TLS_ENDPOINT_NOT_ALLOWED");
            if (raw.isConnected()) return;
            IOException last = null;
            for (String value : CLOUDFLARE_IPV4) {
                Socket candidate = new Socket();
                try {
                    if (localBind != null) candidate.bind(localBind);
                    candidate.setTcpNoDelay(tcpNoDelay);
                    candidate.setKeepAlive(keepAlive);
                    candidate.setSoTimeout(Math.max(0, soTimeout));
                    if (sendBufferSize > 0) candidate.setSendBufferSize(sendBufferSize);
                    if (receiveBufferSize > 0) candidate.setReceiveBufferSize(receiveBufferSize);
                    if (trafficClass >= 0) candidate.setTrafficClass(trafficClass);
                    if (reuseAddress != null) candidate.setReuseAddress(reuseAddress);
                    candidate.connect(new InetSocketAddress(addressFor(value), HTTPS_PORT),
                        timeout > 0 ? Math.min(timeout, CONNECT_TIMEOUT_MS) : CONNECT_TIMEOUT_MS);
                    raw.close();
                    raw = candidate;
                    return;
                } catch (IOException ex) {
                    last = ex;
                    try { candidate.close(); } catch (IOException ignored) {}
                }
            }
            throw new IOException("CLOUDFLARE_PINNED_GATEWAY_CONNECT_FAILED", last);
        }

        @Override public InputStream getInputStream() throws IOException { return raw.getInputStream(); }
        @Override public OutputStream getOutputStream() throws IOException { return raw.getOutputStream(); }
        @Override public void close() throws IOException { closed = true; raw.close(); }
        @Override public void shutdownInput() throws IOException { raw.shutdownInput(); }
        @Override public void shutdownOutput() throws IOException { raw.shutdownOutput(); }
        @Override public boolean isConnected() { return raw.isConnected(); }
        @Override public boolean isBound() { return raw.isBound(); }
        @Override public boolean isClosed() { return closed || raw.isClosed(); }
        @Override public boolean isInputShutdown() { return raw.isInputShutdown(); }
        @Override public boolean isOutputShutdown() { return raw.isOutputShutdown(); }
        @Override public InetAddress getInetAddress() { return raw.getInetAddress(); }
        @Override public InetAddress getLocalAddress() { return raw.getLocalAddress(); }
        @Override public int getPort() { return raw.getPort(); }
        @Override public int getLocalPort() { return raw.getLocalPort(); }
        @Override public SocketAddress getRemoteSocketAddress() { return raw.getRemoteSocketAddress(); }
        @Override public SocketAddress getLocalSocketAddress() { return raw.getLocalSocketAddress(); }
        @Override public SocketChannel getChannel() { return null; }
        @Override public void setTcpNoDelay(boolean value) throws SocketException { tcpNoDelay = value; raw.setTcpNoDelay(value); }
        @Override public boolean getTcpNoDelay() throws SocketException { return raw.getTcpNoDelay(); }
        @Override public void setKeepAlive(boolean value) throws SocketException { keepAlive = value; raw.setKeepAlive(value); }
        @Override public boolean getKeepAlive() throws SocketException { return raw.getKeepAlive(); }
        @Override public void setSoTimeout(int value) throws SocketException { soTimeout = value; raw.setSoTimeout(value); }
        @Override public int getSoTimeout() throws SocketException { return raw.getSoTimeout(); }
        @Override public void setSendBufferSize(int value) throws SocketException { sendBufferSize = value; raw.setSendBufferSize(value); }
        @Override public int getSendBufferSize() throws SocketException { return raw.getSendBufferSize(); }
        @Override public void setReceiveBufferSize(int value) throws SocketException { receiveBufferSize = value; raw.setReceiveBufferSize(value); }
        @Override public int getReceiveBufferSize() throws SocketException { return raw.getReceiveBufferSize(); }
        @Override public void setTrafficClass(int value) throws SocketException { trafficClass = value; raw.setTrafficClass(value); }
        @Override public int getTrafficClass() throws SocketException { return raw.getTrafficClass(); }
        @Override public void setReuseAddress(boolean value) throws SocketException { reuseAddress = value; raw.setReuseAddress(value); }
        @Override public boolean getReuseAddress() throws SocketException { return raw.getReuseAddress(); }
        @Override public void setSoLinger(boolean on, int seconds) throws SocketException { raw.setSoLinger(on, seconds); }
        @Override public int getSoLinger() throws SocketException { return raw.getSoLinger(); }
        @Override public void setOOBInline(boolean value) throws SocketException { raw.setOOBInline(value); }
        @Override public boolean getOOBInline() throws SocketException { return raw.getOOBInline(); }
        @Override public void sendUrgentData(int data) throws IOException { raw.sendUrgentData(data); }
        @Override public void setPerformancePreferences(int connectionTime, int latency, int bandwidth) {
            raw.setPerformancePreferences(connectionTime, latency, bandwidth);
        }
        @Override public String toString() { return "PinnedGatewayTcpSocket[" + raw + "]"; }
    }
}
