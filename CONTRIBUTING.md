# Contributing to LicenseSeatSDK

Thank you for your interest in contributing to LicenseSeatSDK! We value all contributions, whether they're bug reports, feature requests, documentation improvements, or code changes.

## Code of Conduct

By participating in this project, you agree to abide by our Code of Conduct. Please treat all community members with respect and professionalism.

## How to Contribute

### Reporting Issues

1. **Check existing issues** - Before creating a new issue, please check if it already exists.
2. **Use issue templates** - We provide templates for bug reports and feature requests.
3. **Provide details** - Include Swift version, platform, and minimal reproduction steps.

### Submitting Pull Requests

1. **Fork the repository** and create your branch from `main`.
2. **Follow our coding standards**:
   - Use SwiftLint (configuration provided)
   - Write descriptive commit messages
   - Add tests for new functionality
   - Update documentation as needed

3. **Test your changes**:
   ```bash
   swift test
   swift build --configuration release
   ```

4. **Submit a PR** with:
   - Clear description of changes
   - Reference to any related issues
   - Screenshots/examples if applicable

### Development Setup

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/licenseseat-swift.git
   cd licenseseat-swift
   ```

2. Open in Xcode:
   ```bash
   open Package.swift
   ```

3. Run tests:
   ```bash
   swift test
   ```

### Coding Standards

#### Swift Style Guide

- Follow [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use meaningful variable and function names
- Prefer clarity over brevity
- Document public APIs with DocC comments

#### Example:
```swift
/// Validates a license key against the LicenseSeat API
/// - Parameters:
///   - licenseKey: The license key to validate
///   - options: Optional validation parameters
/// - Returns: Validation result containing license status
/// - Throws: `LicenseSeatError` if validation fails
public func validate(
    licenseKey: String,
    options: ValidationOptions? = nil
) async throws -> LicenseValidationResult {
    // Implementation
}
```

### Testing Guidelines

1. **Unit Tests** - Test individual components in isolation
2. **Integration Tests** - Test component interactions
3. **Mock Network Calls** - Use URLProtocol for network testing
4. **Aim for 80%+ Coverage** - Use `swift test --enable-code-coverage`

### Documentation

- Add DocC comments to all public APIs
- Update README for significant changes
- Include code examples in documentation
- Keep CHANGELOG.md updated

### Release Process

1. Update version in appropriate files
2. Update CHANGELOG.md
3. Create a pull request
4. After merge, tag the release:
   ```bash
   git tag -a v1.0.0 -m "Release version 1.0.0"
   git push origin v1.0.0
   ```

## Getting Help

- 💬 [Discord Community](https://discord.gg/licenseseat)
- 📧 [Email Support](mailto:support@licenseseat.com)
- 📖 [Documentation](https://docs.licenseseat.com)

## Recognition

Contributors will be recognized in our README and release notes. Thank you for helping make LicenseSeatSDK better!

## License

By contributing, you agree that your contributions will be licensed under the MIT License. 