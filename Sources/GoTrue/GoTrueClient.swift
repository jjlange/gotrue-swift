import Combine
import Foundation
import Get

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public final class GoTrueClient {
  private let url: URL
  private let authEventChangeSubject: CurrentValueSubject<AuthChangeEvent, Never>
  public lazy var authEventChange = authEventChangeSubject.share().eraseToAnyPublisher()

  public var session: Session? { Current.sessionManager.storedSession() }

  init(
    url: URL,
    headers: [String: String] = [:],
    keychainAccessGroup: String? = nil,
    configuration: (inout APIClient.Configuration) -> Void
  ) {
    self.url = url
    Current = .live(
      url: url, accessGroup: keychainAccessGroup, headers: headers, configuration: configuration)

    self.authEventChangeSubject = CurrentValueSubject<AuthChangeEvent, Never>(
      Current.sessionManager.storedSession() != nil ? .signedIn : .signedOut
    )
  }

  public convenience init(
    url: URL,
    headers: [String: String] = [:],
    keychainAccessGroup: String? = nil
  ) {
    self.init(
      url: url, headers: headers, keychainAccessGroup: keychainAccessGroup, configuration: { _ in })
  }

  public func signUp(email: String, password: String) async throws -> SessionOrUser {
    await Current.sessionManager.remove()
    let response = try await Current.client.send(
      Paths.signup.post(.init(email: email, password: password))
    ).value

    if let session = response.session {
      try await Current.sessionManager.update(session)
      authEventChangeSubject.send(.signedIn)
    }

    return response
  }

  public func signUp(phone: String, password: String) async throws -> SessionOrUser {
    await Current.sessionManager.remove()
    let response = try await Current.client.send(
      Paths.signup.post(.init(password: password, phone: phone))
    ).value

    if let session = response.session {
      try await Current.sessionManager.update(session)
      authEventChangeSubject.send(.signedIn)
    }

    return response
  }

  public func signIn(email: String, password: String) async throws -> Session {
    await Current.sessionManager.remove()

    do {
      let session = try await Current.client.send(
        Paths.token.post(
          grantType: .password,
          .userCredentials(UserCredentials(email: email, password: password)))
      ).value

      if session.user.emailConfirmedAt != nil || session.user.confirmedAt != nil {
        try await Current.sessionManager.update(session)
        authEventChangeSubject.send(.signedIn)
      }

      return session
    } catch {
      throw error
    }
  }

  public func signIn(phone: String, password: String) async throws -> Session {
    await Current.sessionManager.remove()

    do {
      let session = try await Current.client.send(
        Paths.token.post(
          grantType: .password,
          .userCredentials(UserCredentials(password: password, phone: phone)))
      ).value

      if session.user.phoneConfirmedAt != nil {
        try await Current.sessionManager.update(session)
        authEventChangeSubject.send(.signedIn)
      }

      return session
    } catch {
      throw error
    }
  }

  public func signIn(email: String, redirectURL: URL? = nil) async throws {
    try await Current.client.send(Paths.otp.post(redirectURL: redirectURL, .init(email: email)))
  }

  public func signIn(provider: Provider, scopes: String? = nil, redirectURL: URL? = nil) throws
    -> URL
  {
    guard
      var components = URLComponents(
        url: url.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)
    else {
      throw URLError(.badURL)
    }

    var queryItems: [URLQueryItem] = [
      URLQueryItem(name: "provider", value: provider.rawValue)
    ]

    if let scopes = scopes {
      queryItems.append(URLQueryItem(name: "scopes", value: scopes))
    }

    if let redirectURL = redirectURL {
      queryItems.append(URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString))
    }

    components.queryItems = queryItems

    guard let url = components.url else {
      throw URLError(.badURL)
    }

    return url
  }

  public func refreshSession(refreshToken: String) async throws -> Session {
    do {
      let session = try await Current.client.send(
        Paths.token.post(
          grantType: .refreshToken,
          .userCredentials(UserCredentials(refreshToken: refreshToken))
        )
      ).value

      if session.user.phoneConfirmedAt != nil || session.user.emailConfirmedAt != nil
        || session.user.confirmedAt != nil
      {
        try await Current.sessionManager.update(session)
        authEventChangeSubject.send(.signedIn)
      }

      return session
    } catch {
      throw error
    }
  }

  public func session(from url: URL) async throws -> Session {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw URLError(.badURL)
    }

    if let errorDescription = components.queryItems?.first(where: { $0.name == "error_description" }
    )?.value {
      throw GoTrueError(errorDescription: errorDescription)
    }

    guard
      let queryItems = components.queryItems,
      let accessToken = queryItems.first(where: { $0.name == "access_token " })?.value,
      let expiresIn = queryItems.first(where: { $0.name == "expires_in" })?.value,
      let refreshToken = queryItems.first(where: { $0.name == "refresh_token" })?.value,
      let tokenType = queryItems.first(where: { $0.name == "token_type" })?.value
    else {
      throw URLError(.badURL)
    }

    let providerToken = queryItems.first(where: { $0.name == "provider_token" })?.value

    let user = try await Current.client.send(Paths.user.get.withAuthoriztion(accessToken)).value

    let session = Session(
      providerToken: providerToken,
      accessToken: accessToken,
      tokenType: tokenType,
      expiresIn: Double(expiresIn) ?? 0,
      refreshToken: refreshToken,
      user: user
    )

    try await Current.sessionManager.update(session)
    authEventChangeSubject.send(.signedIn)

    if let type = queryItems.first(where: { $0.name == "type" })?.value, type == "recovery" {
      authEventChangeSubject.send(.passwordRecovery)
    }

    return session
  }

  public func signOut() async throws {
    let session = try await Current.sessionManager.session()
    try await Current.client.send(Paths.logout.post.withAuthoriztion(session.accessToken)).value
    await Current.sessionManager.remove()
    authEventChangeSubject.send(.signedOut)
  }

  public func verifyOTP(params: VerifyOTPParams) async throws -> SessionOrUser {
    let response = try await Current.client.send(Paths.verify.post(params)).value

    if let session = response.session {
      try await Current.sessionManager.update(session)
      authEventChangeSubject.send(.signedIn)
    }

    return response
  }

  public func update(user: UserAttributes) async throws -> User {
    var session = try await Current.sessionManager.session()
    let user = try await Current.client.send(
      Paths.user.put(user).withAuthoriztion(session.accessToken)
    ).value
    session.user = user
    try await Current.sessionManager.update(session)
    authEventChangeSubject.send(.userUpdated)
    return user
  }

  /// Sends a reset request to an email address.
  /// - Parameters:
  ///   - email: The email address of the user.
  ///   - redirectURL: A URL or mobile address to send the user to after they are confirmed.
  public func resetPasswordForEmail(
    _ email: String, redirectURL: URL? = nil, captchaToken: String? = nil
  ) async throws {
    try await Current.client.send(
      Paths.recover.post(
        redirectURL: redirectURL,
        RecoverParams(
          email: email,
          gotrueMetaSecurity: captchaToken.map(GoTrueMetaSecurity.init(hcaptchaToken:))
        )
      )
    ).value
  }
}
