-- Notification Service Database Schema

-- Notifications table
CREATE TABLE IF NOT EXISTS notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(255) NOT NULL,
    channel VARCHAR(20) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    priority VARCHAR(20) DEFAULT 'NORMAL',

    -- Template information
    template_id UUID,
    template_name VARCHAR(255),

    -- Recipient information
    recipient_id UUID,
    recipient_email VARCHAR(255),
    recipient_phone VARCHAR(50),
    recipient_token TEXT,

    -- Message content
    subject VARCHAR(500),
    body TEXT,
    body_html TEXT,
    variables JSONB,
    metadata JSONB,

    -- Delivery tracking
    scheduled_for TIMESTAMP,
    sent_at TIMESTAMP,
    delivered_at TIMESTAMP,
    failed_at TIMESTAMP,
    error_message TEXT,
    retry_count INT DEFAULT 0,
    max_retries INT DEFAULT 3,

    -- Provider information
    provider VARCHAR(100),
    provider_id VARCHAR(255),
    provider_data JSONB,

    -- Tracking
    opened_at TIMESTAMP,
    clicked_at TIMESTAMP,
    unsubscribed_at TIMESTAMP,

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP
);

-- Notification templates table
CREATE TABLE IF NOT EXISTS notification_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    channel VARCHAR(20) NOT NULL,
    category VARCHAR(100),

    -- Template content
    subject VARCHAR(500),
    body_template TEXT,
    html_template TEXT,

    -- Template configuration
    variables JSONB,
    default_data JSONB,

    -- Versioning
    version INT DEFAULT 1,
    is_active BOOLEAN DEFAULT TRUE,
    is_system BOOLEAN DEFAULT FALSE,

    -- Metadata
    tags JSONB,

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),
    deleted_at TIMESTAMP,

    UNIQUE(name, tenant_id)
);

-- Notification preferences table
CREATE TABLE IF NOT EXISTS notification_preferences (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(255) NOT NULL,
    user_id UUID NOT NULL,

    -- Channel preferences
    email_enabled BOOLEAN DEFAULT TRUE,
    sms_enabled BOOLEAN DEFAULT TRUE,
    push_enabled BOOLEAN DEFAULT TRUE,

    -- Category preferences
    marketing_enabled BOOLEAN DEFAULT TRUE,
    orders_enabled BOOLEAN DEFAULT TRUE,
    security_enabled BOOLEAN DEFAULT TRUE,

    -- Contact information
    email VARCHAR(255),
    phone VARCHAR(50),

    -- Push tokens
    push_tokens JSONB,

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(user_id, tenant_id)
);

-- Notification logs table
CREATE TABLE IF NOT EXISTS notification_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notification_id UUID NOT NULL,
    event VARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    message TEXT,
    data JSONB,
    created_at TIMESTAMP DEFAULT NOW()
);

-- Notification batches table
CREATE TABLE IF NOT EXISTS notification_batches (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    template_id UUID NOT NULL,
    channel VARCHAR(20) NOT NULL,

    -- Batch stats
    total_count INT DEFAULT 0,
    sent_count INT DEFAULT 0,
    failed_count INT DEFAULT 0,

    status VARCHAR(50) DEFAULT 'PENDING',
    scheduled_for TIMESTAMP,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,

    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_notifications_tenant_id ON notifications(tenant_id);
CREATE INDEX IF NOT EXISTS idx_notifications_channel ON notifications(channel);
CREATE INDEX IF NOT EXISTS idx_notifications_status ON notifications(status);
CREATE INDEX IF NOT EXISTS idx_notifications_template_id ON notifications(template_id);
CREATE INDEX IF NOT EXISTS idx_notifications_recipient_id ON notifications(recipient_id);
CREATE INDEX IF NOT EXISTS idx_notifications_recipient_email ON notifications(recipient_email);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON notifications(created_at);
CREATE INDEX IF NOT EXISTS idx_notifications_scheduled_for ON notifications(scheduled_for);
CREATE INDEX IF NOT EXISTS idx_notifications_deleted_at ON notifications(deleted_at);

CREATE INDEX IF NOT EXISTS idx_templates_tenant_id ON notification_templates(tenant_id);
CREATE INDEX IF NOT EXISTS idx_templates_category ON notification_templates(category);
CREATE INDEX IF NOT EXISTS idx_templates_channel ON notification_templates(channel);
CREATE INDEX IF NOT EXISTS idx_templates_deleted_at ON notification_templates(deleted_at);

CREATE INDEX IF NOT EXISTS idx_preferences_tenant_id ON notification_preferences(tenant_id);
CREATE INDEX IF NOT EXISTS idx_preferences_user_id ON notification_preferences(user_id);

CREATE INDEX IF NOT EXISTS idx_logs_notification_id ON notification_logs(notification_id);
CREATE INDEX IF NOT EXISTS idx_logs_created_at ON notification_logs(created_at);

CREATE INDEX IF NOT EXISTS idx_batches_tenant_id ON notification_batches(tenant_id);
CREATE INDEX IF NOT EXISTS idx_batches_status ON notification_batches(status);
CREATE INDEX IF NOT EXISTS idx_batches_scheduled_for ON notification_batches(scheduled_for);

-- Insert system notification templates

-- Email Templates
INSERT INTO notification_templates (tenant_id, name, description, channel, category, subject, body_template, html_template, variables, is_system) VALUES
-- Onboarding
('default-tenant', 'onboarding_welcome', 'Welcome email after account creation', 'EMAIL', 'onboarding',
'Welcome to {{.CompanyName}}!',
'Hi {{.FirstName}},

Welcome to {{.CompanyName}}! We''re excited to have you on board.

Your account has been successfully created. You can now start exploring our platform.

{{if .OnboardingLink}}
Complete your onboarding: {{.OnboardingLink}}
{{end}}

Best regards,
The {{.CompanyName}} Team',
'<html><body><h1>Welcome to {{.CompanyName}}!</h1><p>Hi {{.FirstName}},</p><p>Welcome to {{.CompanyName}}! We''re excited to have you on board.</p>{{if .OnboardingLink}}<p><a href="{{.OnboardingLink}}" style="background:#4F46E5;color:white;padding:12px 24px;text-decoration:none;border-radius:6px;display:inline-block;margin:20px 0;">Complete Onboarding</a></p>{{end}}<p>Best regards,<br>The {{.CompanyName}} Team</p></body></html>',
'{"CompanyName": "Company name", "FirstName": "User first name", "OnboardingLink": "Onboarding completion link"}',
TRUE),

('default-tenant', 'onboarding_verification', 'Email verification for onboarding', 'EMAIL', 'onboarding',
'Verify your email address',
'Hi {{.FirstName}},

Please verify your email address by clicking the link below:

{{.VerificationLink}}

This link will expire in {{.ExpiryHours}} hours.

If you didn''t request this, please ignore this email.

Best regards,
The {{.CompanyName}} Team',
'<html><body><h1>Verify Your Email</h1><p>Hi {{.FirstName}},</p><p>Please verify your email address by clicking the button below:</p><p><a href="{{.VerificationLink}}" style="background:#4F46E5;color:white;padding:12px 24px;text-decoration:none;border-radius:6px;display:inline-block;margin:20px 0;">Verify Email</a></p><p><small>This link will expire in {{.ExpiryHours}} hours.</small></p></body></html>',
'{"CompanyName": "Company name", "FirstName": "User first name", "VerificationLink": "Verification URL", "ExpiryHours": "Link expiry hours"}',
TRUE),

-- Order notifications
('default-tenant', 'order_confirmation', 'Order confirmation email', 'EMAIL', 'orders',
'Order Confirmation - {{.OrderNumber}}',
'Hi {{.CustomerName}},

Thank you for your order! Your order has been confirmed.

Order Number: {{.OrderNumber}}
Order Date: {{.OrderDate}}
Total: {{.Currency}}{{.Total}}

{{range .Items}}
- {{.ProductName}} x {{.Quantity}} - {{$.Currency}}{{.Price}}
{{end}}

Shipping Address:
{{.ShippingAddress}}

You can track your order at: {{.TrackingLink}}

Best regards,
{{.CompanyName}}',
'<html><body><h1>Order Confirmation</h1><p>Hi {{.CustomerName}},</p><p>Thank you for your order!</p><table><tr><th>Order Number</th><td>{{.OrderNumber}}</td></tr><tr><th>Date</th><td>{{.OrderDate}}</td></tr><tr><th>Total</th><td>{{.Currency}}{{.Total}}</td></tr></table><h3>Items:</h3><ul>{{range .Items}}<li>{{.ProductName}} x {{.Quantity}} - {{$.Currency}}{{.Price}}</li>{{end}}</ul><p><a href="{{.TrackingLink}}" style="background:#4F46E5;color:white;padding:12px 24px;text-decoration:none;border-radius:6px;display:inline-block;margin:20px 0;">Track Order</a></p></body></html>',
'{"CustomerName": "Customer name", "OrderNumber": "Order number", "OrderDate": "Order date", "Total": "Total amount", "Currency": "Currency symbol", "Items": "Array of order items", "ShippingAddress": "Shipping address", "TrackingLink": "Order tracking link", "CompanyName": "Company name"}',
TRUE),

('default-tenant', 'order_shipped', 'Order shipped notification', 'EMAIL', 'orders',
'Your Order Has Shipped - {{.OrderNumber}}',
'Hi {{.CustomerName}},

Great news! Your order {{.OrderNumber}} has been shipped.

Tracking Number: {{.TrackingNumber}}
Carrier: {{.Carrier}}
Estimated Delivery: {{.EstimatedDelivery}}

Track your shipment: {{.TrackingLink}}

Best regards,
{{.CompanyName}}',
'<html><body><h1>Your Order Has Shipped!</h1><p>Hi {{.CustomerName}},</p><p>Great news! Your order <strong>{{.OrderNumber}}</strong> has been shipped.</p><table><tr><th>Tracking Number</th><td>{{.TrackingNumber}}</td></tr><tr><th>Carrier</th><td>{{.Carrier}}</td></tr><tr><th>Estimated Delivery</th><td>{{.EstimatedDelivery}}</td></tr></table><p><a href="{{.TrackingLink}}" style="background:#4F46E5;color:white;padding:12px 24px;text-decoration:none;border-radius:6px;display:inline-block;margin:20px 0;">Track Shipment</a></p></body></html>',
'{"CustomerName": "Customer name", "OrderNumber": "Order number", "TrackingNumber": "Shipping tracking number", "Carrier": "Shipping carrier", "EstimatedDelivery": "Estimated delivery date", "TrackingLink": "Tracking URL", "CompanyName": "Company name"}',
TRUE),

-- Return notifications
('default-tenant', 'return_approved', 'Return request approved', 'EMAIL', 'returns',
'Return Approved - RMA {{.RMANumber}}',
'Hi {{.CustomerName}},

Your return request has been approved.

RMA Number: {{.RMANumber}}
Order Number: {{.OrderNumber}}
Refund Amount: {{.Currency}}{{.RefundAmount}}

{{if .ReturnLabel}}
Download return label: {{.ReturnLabel}}
{{end}}

Please ship the items back to us within 7 days.

Best regards,
{{.CompanyName}}',
'<html><body><h1>Return Approved</h1><p>Hi {{.CustomerName}},</p><p>Your return request has been approved.</p><table><tr><th>RMA Number</th><td>{{.RMANumber}}</td></tr><tr><th>Order Number</th><td>{{.OrderNumber}}</td></tr><tr><th>Refund Amount</th><td>{{.Currency}}{{.RefundAmount}}</td></tr></table>{{if .ReturnLabel}}<p><a href="{{.ReturnLabel}}" style="background:#4F46E5;color:white;padding:12px 24px;text-decoration:none;border-radius:6px;display:inline-block;margin:20px 0;">Download Return Label</a></p>{{end}}</body></html>',
'{"CustomerName": "Customer name", "RMANumber": "RMA number", "OrderNumber": "Order number", "RefundAmount": "Refund amount", "Currency": "Currency symbol", "ReturnLabel": "Return shipping label URL", "CompanyName": "Company name"}',
TRUE),

('default-tenant', 'return_completed', 'Return completed and refunded', 'EMAIL', 'returns',
'Refund Processed - RMA {{.RMANumber}}',
'Hi {{.CustomerName}},

Your return has been processed and your refund has been issued.

RMA Number: {{.RMANumber}}
Refund Amount: {{.Currency}}{{.RefundAmount}}
Refund Method: {{.RefundMethod}}

You should see the refund in 3-5 business days.

Best regards,
{{.CompanyName}}',
'<html><body><h1>Refund Processed</h1><p>Hi {{.CustomerName}},</p><p>Your return has been processed and your refund has been issued.</p><table><tr><th>RMA Number</th><td>{{.RMANumber}}</td></tr><tr><th>Refund Amount</th><td>{{.Currency}}{{.RefundAmount}}</td></tr><tr><th>Refund Method</th><td>{{.RefundMethod}}</td></tr></table><p><small>You should see the refund in 3-5 business days.</small></p></body></html>',
'{"CustomerName": "Customer name", "RMANumber": "RMA number", "RefundAmount": "Refund amount", "Currency": "Currency symbol", "RefundMethod": "Refund method", "CompanyName": "Company name"}',
TRUE),

-- Auth notifications
('default-tenant', 'password_reset', 'Password reset request', 'EMAIL', 'auth',
'Reset Your Password',
'Hi {{.Name}},

We received a request to reset your password.

Click here to reset: {{.ResetLink}}

This link will expire in {{.ExpiryHours}} hours.

If you didn''t request this, please ignore this email.

Best regards,
{{.CompanyName}}',
'<html><body><h1>Reset Your Password</h1><p>Hi {{.Name}},</p><p>We received a request to reset your password.</p><p><a href="{{.ResetLink}}" style="background:#4F46E5;color:white;padding:12px 24px;text-decoration:none;border-radius:6px;display:inline-block;margin:20px 0;">Reset Password</a></p><p><small>This link will expire in {{.ExpiryHours}} hours.</small></p></body></html>',
'{"Name": "User name", "ResetLink": "Password reset URL", "ExpiryHours": "Link expiry hours", "CompanyName": "Company name"}',
TRUE)

ON CONFLICT (name, tenant_id) DO NOTHING;
-- Seed system notification templates
-- These templates are used by the NATS subscriber for event-driven notifications

-- Order Confirmation Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'order-confirmation',
    'Email sent when a new order is placed',
    'EMAIL',
    'orders',
    'Order Confirmed - #{{.orderNumber}}',
    'Hi {{.customerName}},

Thank you for your order!

Order Number: {{.orderNumber}}
Total: {{.currency}} {{.totalAmount | currency}}

We will notify you when your order ships.

Thank you for shopping with us!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Order Confirmed!</h1>
<p>Hi {{.customerName}},</p>
<p>Thank you for your order!</p>
<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<p><strong>Order Number:</strong> {{.orderNumber}}</p>
<p><strong>Total:</strong> {{.currency}} {{.totalAmount | currency}}</p>
</div>
<p>We will notify you when your order ships.</p>
<p>Thank you for shopping with us!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Order Shipped Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'order-shipped',
    'Email sent when an order is shipped',
    'EMAIL',
    'orders',
    'Your Order #{{.orderNumber}} Has Shipped!',
    'Hi {{.customerName}},

Great news! Your order has shipped!

Order Number: {{.orderNumber}}
Carrier: {{.carrierName}}
{{if .trackingUrl}}Track your package: {{.trackingUrl}}{{end}}

Thank you for shopping with us!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Your Order Has Shipped!</h1>
<p>Hi {{.customerName}},</p>
<p>Great news! Your order has shipped!</p>
<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<p><strong>Order Number:</strong> {{.orderNumber}}</p>
<p><strong>Carrier:</strong> {{.carrierName}}</p>
{{if .trackingUrl}}<p><a href="{{.trackingUrl}}" style="color: #0066cc;">Track Your Package</a></p>{{end}}
</div>
<p>Thank you for shopping with us!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Order Shipped SMS
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'order-shipped-sms',
    'SMS sent when an order is shipped',
    'SMS',
    'orders',
    '',
    'Your order #{{.orderNumber}} has shipped! {{if .trackingUrl}}Track: {{.trackingUrl}}{{end}}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Order Delivered Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'order-delivered',
    'Email sent when an order is delivered',
    'EMAIL',
    'orders',
    'Your Order #{{.orderNumber}} Has Been Delivered!',
    'Hi {{.customerName}},

Your order has been delivered!

Order Number: {{.orderNumber}}

We hope you love your purchase. If you have any questions, please contact us.

Thank you for shopping with us!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Your Order Has Been Delivered!</h1>
<p>Hi {{.customerName}},</p>
<p>Your order has been delivered!</p>
<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<p><strong>Order Number:</strong> {{.orderNumber}}</p>
</div>
<p>We hope you love your purchase. If you have any questions, please contact us.</p>
<p>Thank you for shopping with us!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Order Delivered SMS
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'order-delivered-sms',
    'SMS sent when an order is delivered',
    'SMS',
    'orders',
    '',
    'Your order #{{.orderNumber}} has been delivered! Thank you for shopping with us.',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Order Cancelled Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'order-cancelled',
    'Email sent when an order is cancelled',
    'EMAIL',
    'orders',
    'Order #{{.orderNumber}} Has Been Cancelled',
    'Hi {{.customerName}},

Your order has been cancelled.

Order Number: {{.orderNumber}}

If you did not request this cancellation, please contact us immediately.

Thank you.',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Order Cancelled</h1>
<p>Hi {{.customerName}},</p>
<p>Your order has been cancelled.</p>
<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<p><strong>Order Number:</strong> {{.orderNumber}}</p>
</div>
<p>If you did not request this cancellation, please contact us immediately.</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Payment Confirmation Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'payment-confirmation',
    'Email sent when payment is received',
    'EMAIL',
    'orders',
    'Payment Received for Order #{{.orderNumber}}',
    'Hi {{.customerName}},

We have received your payment!

Order Number: {{.orderNumber}}
Amount: {{.currency}} {{.amount | currency}}
Payment Method: {{.provider}}

Thank you!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Payment Received!</h1>
<p>Hi {{.customerName}},</p>
<p>We have received your payment!</p>
<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<p><strong>Order Number:</strong> {{.orderNumber}}</p>
<p><strong>Amount:</strong> {{.currency}} {{.amount | currency}}</p>
<p><strong>Payment Method:</strong> {{.provider}}</p>
</div>
<p>Thank you!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Payment Failed Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'payment-failed',
    'Email sent when payment fails',
    'EMAIL',
    'orders',
    'Payment Failed for Order #{{.orderNumber}}',
    'Hi {{.customerName}},

Unfortunately, your payment could not be processed.

Order Number: {{.orderNumber}}
Amount: {{.currency}} {{.amount | currency}}

Please update your payment method and try again.

If you need assistance, please contact our support team.',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #cc0000;">Payment Failed</h1>
<p>Hi {{.customerName}},</p>
<p>Unfortunately, your payment could not be processed.</p>
<div style="background: #fff5f5; padding: 20px; border-radius: 8px; margin: 20px 0; border: 1px solid #ffcccc;">
<p><strong>Order Number:</strong> {{.orderNumber}}</p>
<p><strong>Amount:</strong> {{.currency}} {{.amount | currency}}</p>
</div>
<p>Please update your payment method and try again.</p>
<p>If you need assistance, please contact our support team.</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Payment Failed SMS
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'payment-failed-sms',
    'SMS sent when payment fails',
    'SMS',
    'orders',
    '',
    'Payment failed for order #{{.orderNumber}}. Please update your payment method.',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Welcome Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'welcome-email',
    'Email sent to new customers',
    'EMAIL',
    'marketing',
    'Welcome to Our Store!',
    'Hi {{.customerName}},

Welcome! We are excited to have you join us.

Your account has been created successfully. You can now browse our products and make purchases.

Happy shopping!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Welcome!</h1>
<p>Hi {{.customerName}},</p>
<p>We are excited to have you join us.</p>
<p>Your account has been created successfully. You can now browse our products and make purchases.</p>
<p>Happy shopping!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Password Reset Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'password-reset',
    'Email sent for password reset',
    'EMAIL',
    'security',
    'Reset Your Password',
    'Hi,

We received a request to reset your password.

Click the link below to reset your password:
{{.resetUrl}}

If you did not request this, please ignore this email.

This link will expire in 1 hour.',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Reset Your Password</h1>
<p>Hi,</p>
<p>We received a request to reset your password.</p>
<div style="text-align: center; margin: 30px 0;">
<a href="{{.resetUrl}}" style="background: #0066cc; color: white; padding: 12px 24px; text-decoration: none; border-radius: 4px;">Reset Password</a>
</div>
<p>If you did not request this, please ignore this email.</p>
<p style="color: #666; font-size: 12px;">This link will expire in 1 hour.</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Verification Code Email
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'verification-code',
    'Email sent with verification code',
    'EMAIL',
    'security',
    'Your Verification Code',
    'Hi,

Your verification code is: {{.verificationCode}}

This code will expire in 10 minutes.

If you did not request this code, please ignore this email.',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
<h1 style="color: #333;">Your Verification Code</h1>
<p>Hi,</p>
<p>Your verification code is:</p>
<div style="text-align: center; margin: 30px 0;">
<span style="background: #f5f5f5; padding: 16px 32px; font-size: 32px; letter-spacing: 8px; font-weight: bold; border-radius: 8px;">{{.verificationCode}}</span>
</div>
<p>This code will expire in 10 minutes.</p>
<p style="color: #666; font-size: 12px;">If you did not request this code, please ignore this email.</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Verification Code SMS
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'system',
    'verification-code-sms',
    'SMS sent with verification code',
    'SMS',
    'security',
    '',
    'Your verification code is {{.verificationCode}}. It expires in 10 minutes.',
    true, true, 1
) ON CONFLICT DO NOTHING;
-- Abandoned Cart Reminder Templates

-- Abandoned Cart Reminder 1 (First reminder, gentle)
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'default-tenant',
    'abandoned_cart_reminder_1',
    'First abandoned cart reminder email',
    'EMAIL',
    'marketing',
    'You left something behind!',
    'Hi {{.customerName}},

You left some items in your shopping cart. Don''t let them get away!

Your Cart:
{{range .cartItems}}- {{.name}} ({{.quantity}}) - ${{.price}}
{{end}}
Total: ${{.cartTotal}}

Complete your purchase now: {{.cartRecoveryUrl}}

See you soon!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
<h1 style="color: #333;">You left something behind!</h1>
<p>Hi {{.customerName}},</p>
<p>You left some items in your shopping cart. Don''t let them get away!</p>

<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<h3 style="margin-top: 0;">Your Cart:</h3>
{{range .cartItems}}
<div style="display: flex; padding: 10px 0; border-bottom: 1px solid #ddd;">
{{if .image}}<img src="{{.image}}" alt="{{.name}}" style="width: 60px; height: 60px; object-fit: cover; border-radius: 4px; margin-right: 15px;">{{end}}
<div>
<p style="margin: 0; font-weight: bold;">{{.name}}</p>
<p style="margin: 5px 0; color: #666;">Qty: {{.quantity}} - ${{.price}}</p>
</div>
</div>
{{end}}
<p style="text-align: right; font-size: 18px; font-weight: bold; margin-top: 15px;">Total: ${{.cartTotal}}</p>
</div>

<div style="text-align: center; margin: 30px 0;">
<a href="{{.cartRecoveryUrl}}" style="background: #4CAF50; color: white; padding: 15px 30px; text-decoration: none; border-radius: 4px; font-size: 16px;">Complete Your Purchase</a>
</div>

<p>See you soon!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Abandoned Cart Reminder 2 (Second reminder, add urgency)
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'default-tenant',
    'abandoned_cart_reminder_2',
    'Second abandoned cart reminder email',
    'EMAIL',
    'marketing',
    'Still thinking about it?',
    'Hi {{.customerName}},

We noticed you haven''t completed your purchase yet. Your items are still waiting for you!

Your Cart:
{{range .cartItems}}- {{.name}} ({{.quantity}}) - ${{.price}}
{{end}}
Total: ${{.cartTotal}}

{{if .discountCode}}
Use code {{.discountCode}} for a special discount!
{{end}}

Complete your purchase now: {{.cartRecoveryUrl}}

Don''t miss out!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
<h1 style="color: #333;">Still thinking about it?</h1>
<p>Hi {{.customerName}},</p>
<p>We noticed you haven''t completed your purchase yet. Your items are still waiting for you!</p>

{{if .discountCode}}
<div style="background: #fff3cd; border: 2px dashed #ffc107; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
<p style="margin: 0; font-size: 14px; color: #856404;">Special Offer!</p>
<p style="margin: 10px 0; font-size: 24px; font-weight: bold; color: #856404;">Use code: {{.discountCode}}</p>
</div>
{{end}}

<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<h3 style="margin-top: 0;">Your Cart:</h3>
{{range .cartItems}}
<div style="display: flex; padding: 10px 0; border-bottom: 1px solid #ddd;">
{{if .image}}<img src="{{.image}}" alt="{{.name}}" style="width: 60px; height: 60px; object-fit: cover; border-radius: 4px; margin-right: 15px;">{{end}}
<div>
<p style="margin: 0; font-weight: bold;">{{.name}}</p>
<p style="margin: 5px 0; color: #666;">Qty: {{.quantity}} - ${{.price}}</p>
</div>
</div>
{{end}}
<p style="text-align: right; font-size: 18px; font-weight: bold; margin-top: 15px;">Total: ${{.cartTotal}}</p>
</div>

<div style="text-align: center; margin: 30px 0;">
<a href="{{.cartRecoveryUrl}}" style="background: #ff9800; color: white; padding: 15px 30px; text-decoration: none; border-radius: 4px; font-size: 16px;">Complete Your Purchase</a>
</div>

<p>Don''t miss out!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- Abandoned Cart Reminder 3 (Final reminder, last chance)
INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template, is_active, is_system, version
) VALUES (
    gen_random_uuid(),
    'default-tenant',
    'abandoned_cart_reminder_3',
    'Final abandoned cart reminder email',
    'EMAIL',
    'marketing',
    'Last chance to complete your order!',
    'Hi {{.customerName}},

This is your last reminder! Your cart items won''t be saved forever.

Your Cart:
{{range .cartItems}}- {{.name}} ({{.quantity}}) - ${{.price}}
{{end}}
Total: ${{.cartTotal}}

{{if .discountCode}}
Use code {{.discountCode}} for a special discount - this is your last chance!
{{end}}

Complete your purchase now: {{.cartRecoveryUrl}}

We hope to see you soon!',
    '<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
<h1 style="color: #d32f2f;">Last chance to complete your order!</h1>
<p>Hi {{.customerName}},</p>
<p>This is your last reminder! Your cart items won''t be saved forever.</p>

{{if .discountCode}}
<div style="background: #ffebee; border: 2px solid #d32f2f; padding: 20px; border-radius: 8px; margin: 20px 0; text-align: center;">
<p style="margin: 0; font-size: 14px; color: #d32f2f;">FINAL OFFER!</p>
<p style="margin: 10px 0; font-size: 24px; font-weight: bold; color: #d32f2f;">Use code: {{.discountCode}}</p>
<p style="margin: 0; font-size: 12px; color: #666;">This is your last chance!</p>
</div>
{{end}}

<div style="background: #f5f5f5; padding: 20px; border-radius: 8px; margin: 20px 0;">
<h3 style="margin-top: 0;">Your Cart:</h3>
{{range .cartItems}}
<div style="display: flex; padding: 10px 0; border-bottom: 1px solid #ddd;">
{{if .image}}<img src="{{.image}}" alt="{{.name}}" style="width: 60px; height: 60px; object-fit: cover; border-radius: 4px; margin-right: 15px;">{{end}}
<div>
<p style="margin: 0; font-weight: bold;">{{.name}}</p>
<p style="margin: 5px 0; color: #666;">Qty: {{.quantity}} - ${{.price}}</p>
</div>
</div>
{{end}}
<p style="text-align: right; font-size: 18px; font-weight: bold; margin-top: 15px;">Total: ${{.cartTotal}}</p>
</div>

<div style="text-align: center; margin: 30px 0;">
<a href="{{.cartRecoveryUrl}}" style="background: #d32f2f; color: white; padding: 15px 30px; text-decoration: none; border-radius: 4px; font-size: 16px;">Complete Your Purchase Now</a>
</div>

<p>We hope to see you soon!</p>
</body>
</html>',
    true, true, 1
) ON CONFLICT DO NOTHING;
-- 004_reseed_email_templates.sql
-- Clean reseed of all email templates with professional design.
--
-- Design system:
--   - Zinc palette (neutral gray, no blue tint)
--   - White card with 3px accent line at top (brand color)
--   - Logo/name inside card, centered
--   - Clean typography, system font stack
--   - Subtle info boxes (#fafafa, no border)
--   - Minimal footer (store name + "Powered by mark8ly" for store emails, "Powered by mark8ly" for platform emails)
--
-- Template types:
--   - 18 mark8ly templates (tenant_id = 'default-tenant') — use brand_primary_color, brand_logo_url
--   - 4 platform templates (tenant_id = 'platform') — use platform_logo_url
--
-- Variable convention: snake_case (matches frontend EmailTemplate interface)

BEGIN;

-- Wipe old seeds so we start clean
DELETE FROM notification_templates WHERE tenant_id IN ('system', 'default-tenant', 'platform');

-- ============================================================================
-- MARK8LY TEMPLATES (tenant_id = 'default-tenant')
-- ============================================================================

-- ─── ORDER ──────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Order Confirmation',
    'Sent to the customer when a new order is placed',
    'EMAIL', 'order',
    'Order confirmed — #{{.order_id}}',
    'Hi {{.customer_name}},

Thanks for your order. We''ll send you an update when it ships.

Order: {{.order_id}}
Total: {{.order_total}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Order confirmed</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Order #{{.order_id}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, thanks for your order. We''ll send you an update when it ships.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Order number</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.order_id}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Total</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.order_total}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View order</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"order_id":"","customer_name":"","customer_email":"","order_total":"","order_items":"","order_status":"","store_name":"","store_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Order Shipped',
    'Sent when an order has shipped with tracking info',
    'EMAIL', 'order',
    'Your order #{{.order_id}} is on the way',
    'Hi {{.customer_name}},

Your order has shipped.

Order: {{.order_id}}
Tracking: {{.tracking_number}}
Track: {{.tracking_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Your order is on the way</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Order #{{.order_id}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your order has shipped. You can track it using the details below.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Tracking number</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.tracking_number}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.tracking_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Track package</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"order_id":"","customer_name":"","tracking_number":"","tracking_url":"","store_name":"","store_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Order Cancelled',
    'Sent when an order is cancelled',
    'EMAIL', 'order',
    'Order #{{.order_id}} has been cancelled',
    'Hi {{.customer_name}},

Your order #{{.order_id}} has been cancelled. If you didn''t request this, please contact us.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Order cancelled</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Order #{{.order_id}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your order has been cancelled. If you didn''t request this, please reach out to us.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Contact support</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"order_id":"","customer_name":"","store_name":"","store_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── PAYMENT ────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Payment Confirmation',
    'Sent when a payment is successfully processed',
    'EMAIL', 'payment',
    'Payment received — {{.payment_amount}}',
    'Hi {{.customer_name}},

We''ve received your payment of {{.payment_amount}}.

Transaction: {{.transaction_id}}
Method: {{.payment_method}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Payment received</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.payment_amount}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your payment has been processed successfully.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Amount</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.payment_amount}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Transaction</p>
        <p style="margin:0 0 14px;font-size:13px;color:#3f3f46;font-family:''SF Mono'',SFMono-Regular,Menlo,monospace;">{{.transaction_id}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Method</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.payment_method}}</p>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","payment_amount":"","payment_method":"","transaction_id":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Payment Failed',
    'Sent when a payment attempt fails',
    'EMAIL', 'payment',
    'Payment failed — action required',
    'Hi {{.customer_name}},

Your payment of {{.payment_amount}} could not be processed. Please update your payment method and try again.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Payment failed</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Action required</p>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your payment of <strong>{{.payment_amount}}</strong> could not be processed. Please update your payment method and try again.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Update payment</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","payment_amount":"","store_name":"","store_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── CUSTOMER ───────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Customer Welcome',
    'Sent to new customers when they create an account',
    'EMAIL', 'customer',
    'Welcome to {{.store_name}}',
    'Hi {{.customer_name}},

Welcome to {{.store_name}}. Your account is ready.

Start browsing: {{.store_url}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Welcome to {{.store_name}}</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your account is ready. You can now browse products, track orders, and more.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Start shopping</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","customer_email":"","store_name":"","store_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── AUTH ────────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Password Reset',
    'Sent when a user requests a password reset',
    'EMAIL', 'auth',
    'Reset your password',
    'We received a request to reset your password.

Reset here: {{.reset_url}}

If you didn''t request this, ignore this email. This link expires in 1 hour.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Reset your password</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">We received a request to reset your password. Click below to choose a new one.</p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.reset_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Reset password</a>
      </td></tr></table>
      <p style="margin:0;font-size:13px;line-height:1.5;color:#a1a1aa;">If you didn''t request this, you can ignore this email. This link expires in 1 hour.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"user_name":"","user_email":"","reset_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Email Verification',
    'Sent to verify a user''s email address',
    'EMAIL', 'auth',
    'Verify your email',
    'Your verification code is: {{.verification_code}}

This code expires in 10 minutes.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Verify your email</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Enter this code to verify your email address:</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="text-align:center;padding:24px;background:#fafafa;border-radius:8px;">
        <span style="font-size:32px;font-weight:700;letter-spacing:6px;color:#18181b;">{{.verification_code}}</span>
      </td></tr></table>
      <p style="margin:0;font-size:13px;color:#a1a1aa;text-align:center;">This code expires in 10 minutes.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"user_name":"","user_email":"","verification_code":"","verification_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── REVIEW ─────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Review Request',
    'Sent to ask a customer to review their purchase',
    'EMAIL', 'review',
    'How was {{.product_name}}?',
    'Hi {{.customer_name}},

We''d love to hear what you think of {{.product_name}}.

Leave a review: {{.review_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">How was your purchase?</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, we''d love to hear what you think of <strong>{{.product_name}}</strong>. Your feedback helps other shoppers.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.review_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Write a review</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","product_name":"","review_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── TICKET ─────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Ticket Created',
    'Sent when a support ticket is created',
    'EMAIL', 'ticket',
    'Re: {{.ticket_subject}} (#{{.ticket_id}})',
    'Hi {{.customer_name}},

We''ve received your request and will get back to you shortly.

Ticket: {{.ticket_id}}
Subject: {{.ticket_subject}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">We got your message</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Ticket #{{.ticket_id}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, we''ve received your request and will get back to you shortly.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Subject</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.ticket_subject}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.ticket_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View ticket</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"ticket_id":"","customer_name":"","ticket_subject":"","ticket_status":"","ticket_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── VENDOR ─────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Vendor Application Received',
    'Sent when a new vendor applies to sell on the marketplace',
    'EMAIL', 'vendor',
    'New vendor application — {{.vendor_name}}',
    'A new vendor has applied to {{.store_name}}.

Vendor: {{.vendor_name}} ({{.vendor_email}})

Review: {{.action_url}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">New vendor application</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">A new vendor has applied to sell on your marketplace.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Vendor</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.vendor_name}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Email</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.vendor_email}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.action_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Review application</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"vendor_name":"","vendor_email":"","store_name":"","action_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── COUPON ─────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Coupon Created',
    'Sent when a new coupon is available for a customer',
    'EMAIL', 'coupon',
    'Your discount code: {{.coupon_code}}',
    'Hi {{.customer_name}},

Use code {{.coupon_code}} to get {{.discount_amount}} off.

Expires: {{.expiry_date}}

Shop now: {{.store_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">You have a discount</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, here''s a discount code for you:</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 8px;"><tr><td style="text-align:center;padding:24px;background:#fafafa;border:1px dashed #e4e4e7;border-radius:8px;">
        <p style="margin:0 0 6px;font-size:24px;font-weight:700;letter-spacing:2px;color:#18181b;">{{.coupon_code}}</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#71717a;">{{.discount_amount}} off</p>
      </td></tr></table>
      <p style="margin:0 0 24px;font-size:13px;color:#a1a1aa;text-align:center;">Expires {{.expiry_date}}</p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto;"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Shop now</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","coupon_code":"","discount_amount":"","expiry_date":"","store_name":"","store_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── INVENTORY ──────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Low Stock Alert',
    'Sent to store admin when product stock falls below threshold',
    'EMAIL', 'inventory',
    'Low stock: {{.product_name}}',
    'Low stock warning for {{.product_name}} (SKU: {{.sku}}).

Current stock: {{.current_stock}} (threshold: {{.threshold}})

Manage inventory: {{.inventory_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Low stock alert</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">A product has fallen below its stock threshold and may need restocking.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Product</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.product_name}} ({{.sku}})</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Current stock</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.current_stock}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Threshold</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.threshold}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.inventory_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Manage inventory</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"product_name":"","sku":"","current_stock":"","threshold":"","store_name":"","inventory_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── APPROVAL ───────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Approval Required',
    'Sent when an item needs approval',
    'EMAIL', 'approval',
    'Approval needed: {{.item_name}}',
    '{{.requester_name}} submitted "{{.item_name}}" for approval.

Type: {{.approval_type}}
Review: {{.approval_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Approval needed</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;"><strong>{{.requester_name}}</strong> submitted an item for your review.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Item</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.item_name}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Type</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.approval_type}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.approval_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Review</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"requester_name":"","approval_type":"","item_name":"","approval_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── DOMAIN ─────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain Verified',
    'Sent when a custom domain passes DNS verification',
    'EMAIL', 'domain',
    'Domain verified: {{.domain_name}}',
    'Your domain {{.domain_name}} has been verified and is now active.

DNS: {{.dns_status}}
SSL: {{.ssl_status}}

Manage domains: {{.settings_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Domain verified</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Your custom domain is now active and serving traffic.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Domain</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.domain_name}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">DNS</p>
        <p style="margin:0 0 14px;font-size:15px;color:#3f3f46;">{{.dns_status}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">SSL</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.ssl_status}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.settings_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Manage domains</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"domain_name":"","dns_status":"","ssl_status":"","store_name":"","settings_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── CAMPAIGN ───────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Campaign Launched',
    'Sent to admin when a marketing campaign goes live',
    'EMAIL', 'campaign',
    'Campaign live: {{.campaign_name}}',
    'Your campaign "{{.campaign_name}}" is now live.

Runs: {{.start_date}} - {{.end_date}}

View: {{.campaign_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Campaign is live</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Your campaign is now active and reaching customers.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Campaign</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.campaign_name}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Duration</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.start_date}} &ndash; {{.end_date}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.campaign_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View campaign</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"campaign_name":"","campaign_status":"","start_date":"","end_date":"","store_name":"","campaign_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── GIFT CARD ──────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Gift Card Received',
    'Sent to the recipient of a gift card',
    'EMAIL', 'gift_card',
    'You received a gift card from {{.sender_name}}',
    'Hi {{.recipient_name}},

{{.sender_name}} sent you a {{.gift_card_amount}} gift card.

Code: {{.gift_card_code}}
Message: {{.gift_card_message}}

Redeem: {{.redeem_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">You received a gift card</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.recipient_name}}, <strong>{{.sender_name}}</strong> sent you a gift card.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 8px;"><tr><td style="text-align:center;padding:24px;background:#fafafa;border:1px dashed #e4e4e7;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Value</p>
        <p style="margin:0 0 16px;font-size:28px;font-weight:700;color:#18181b;">{{.gift_card_amount}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Code</p>
        <p style="margin:0;font-size:18px;font-weight:600;letter-spacing:2px;color:#18181b;">{{.gift_card_code}}</p>
      </td></tr></table>
      {{if .gift_card_message}}<p style="margin:16px 0 0;font-size:14px;color:#71717a;text-align:center;font-style:italic;">&ldquo;{{.gift_card_message}}&rdquo;</p>{{end}}
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px auto 0;"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.redeem_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Redeem now</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"recipient_name":"","sender_name":"","gift_card_code":"","gift_card_amount":"","gift_card_message":"","redeem_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── STAFF ──────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Staff Invitation',
    'Sent when a staff member is invited to the store',
    'EMAIL', 'staff',
    'You''re invited to join {{.store_name}}',
    'Hi {{.staff_name}},

{{.inviter_name}} invited you to join {{.store_name}} as {{.role}}.

Accept: {{.invite_url}}

This invitation expires in 7 days.',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">You''re invited</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.staff_name}}, <strong>{{.inviter_name}}</strong> invited you to join <strong>{{.store_name}}</strong> as <strong>{{.role}}</strong>.</p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.invite_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Accept invitation</a>
      </td></tr></table>
      <p style="margin:0;font-size:13px;color:#a1a1aa;">This invitation expires in 7 days.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"staff_name":"","staff_email":"","role":"","inviter_name":"","invite_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── TENANT ONBOARDING ────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Tenant Welcome Pack',
    'Sent to new store owners when their store is created',
    'EMAIL', 'tenant_onboarding',
    'Your store is ready — {{.business_name}}',
    'Congratulations! Your store {{.business_name}} has been successfully created.

Admin Panel: {{.admin_url}}
Storefront: {{.storefront_url}}

Email: {{.email}}

Quick Start:
1. Add your products
2. Configure payments
3. Set up shipping
4. Customize your store

Need help? Contact {{.support_email}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 0;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Your store is ready</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.business_name}} is now live</p>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Congratulations! Your store <strong>{{.business_name}}</strong> has been successfully created. Here''s everything you need to get started.</p>
      <p style="margin:0 0 12px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;font-weight:600;">Your store URLs</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 8px;"><tr><td style="padding:14px 16px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;">Admin Panel</p>
        <a href="{{.admin_url}}" style="font-size:14px;color:#18181b;font-weight:500;text-decoration:none;word-break:break-all;">{{.admin_url}}</a>
      </td></tr></table>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:14px 16px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;">Storefront</p>
        <a href="{{.storefront_url}}" style="font-size:14px;color:#18181b;font-weight:500;text-decoration:none;word-break:break-all;">{{.storefront_url}}</a>
      </td></tr></table>
      <p style="margin:0 0 16px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;font-weight:600;">Quick start</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;">
        <tr>
          <td style="width:28px;vertical-align:top;padding:0 0 14px;"><div style="width:24px;height:24px;background:#f4f4f5;border-radius:50%;text-align:center;line-height:24px;font-size:12px;font-weight:600;color:#52525b;">1</div></td>
          <td style="vertical-align:top;padding:2px 0 14px 10px;"><p style="margin:0 0 2px;font-size:14px;font-weight:600;color:#18181b;">Add your products</p><p style="margin:0;font-size:13px;color:#71717a;line-height:1.5;">Upload inventory, set prices, and configure variants</p></td>
        </tr>
        <tr>
          <td style="width:28px;vertical-align:top;padding:0 0 14px;"><div style="width:24px;height:24px;background:#f4f4f5;border-radius:50%;text-align:center;line-height:24px;font-size:12px;font-weight:600;color:#52525b;">2</div></td>
          <td style="vertical-align:top;padding:2px 0 14px 10px;"><p style="margin:0 0 2px;font-size:14px;font-weight:600;color:#18181b;">Configure payments</p><p style="margin:0;font-size:13px;color:#71717a;line-height:1.5;">Connect Stripe, PayPal, or Razorpay to accept payments</p></td>
        </tr>
        <tr>
          <td style="width:28px;vertical-align:top;padding:0 0 14px;"><div style="width:24px;height:24px;background:#f4f4f5;border-radius:50%;text-align:center;line-height:24px;font-size:12px;font-weight:600;color:#52525b;">3</div></td>
          <td style="vertical-align:top;padding:2px 0 14px 10px;"><p style="margin:0 0 2px;font-size:14px;font-weight:600;color:#18181b;">Set up shipping</p><p style="margin:0;font-size:13px;color:#71717a;line-height:1.5;">Define shipping zones, rates, and delivery options</p></td>
        </tr>
        <tr>
          <td style="width:28px;vertical-align:top;padding:0 0 0;"><div style="width:24px;height:24px;background:#f4f4f5;border-radius:50%;text-align:center;line-height:24px;font-size:12px;font-weight:600;color:#52525b;">4</div></td>
          <td style="vertical-align:top;padding:2px 0 0 10px;"><p style="margin:0 0 2px;font-size:14px;font-weight:600;color:#18181b;">Customize your store</p><p style="margin:0;font-size:13px;color:#71717a;line-height:1.5;">Brand your storefront, add pages, and configure settings</p></td>
        </tr>
      </table>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 16px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 10px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;font-weight:600;">Account details</p>
        <table role="presentation" cellpadding="0" cellspacing="0" width="100%">
          <tr><td style="padding:2px 0;font-size:13px;color:#71717a;width:60px;">Email</td><td style="padding:2px 0 2px 8px;font-size:14px;color:#18181b;font-weight:500;">{{.email}}</td></tr>
          <tr><td style="padding:2px 0;font-size:13px;color:#71717a;width:60px;">Store</td><td style="padding:2px 0 2px 8px;font-size:14px;color:#18181b;font-weight:500;">{{.business_name}}</td></tr>
          {{if .tenant_slug}}<tr><td style="padding:2px 0;font-size:13px;color:#71717a;width:60px;">ID</td><td style="padding:2px 0 2px 8px;font-size:14px;color:#18181b;font-weight:500;font-family:''SF Mono'',SFMono-Regular,Menlo,monospace;">{{.tenant_slug}}</td></tr>{{end}}
        </table>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0" align="center"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.admin_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Open Admin Panel &rarr;</a>
      </td></tr></table>
    </td></tr>
    <tr><td style="height:36px;"></td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0 0 8px;font-size:13px;color:#71717a;">Need help? <a href="mailto:{{.support_email}}" style="color:#18181b;text-decoration:none;font-weight:500;">Contact support</a></p>
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"business_name":"","admin_url":"","storefront_url":"","email":"","tenant_slug":"","support_email":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ============================================================================
-- PLATFORM TEMPLATES (tenant_id = 'platform')
-- ============================================================================

-- ─── SYSTEM HEALTH ──────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'platform',
    'System Health Alert',
    'Sent when a service health issue is detected',
    'EMAIL', 'system_health',
    '[{{.alert_type}}] {{.service_name}} — {{.environment}}',
    'System Alert: {{.alert_type}}

Service: {{.service_name}}
Environment: {{.environment}}
Time: {{.timestamp}}

{{.alert_message}}

Dashboard: {{.dashboard_url}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:#18181b;border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .platform_logo_url}}<img src="{{.platform_logo_url}}" alt="mark8ly" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">mark8ly</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">System health alert</h1>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fef2f2;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Service</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.service_name}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Environment</p>
        <p style="margin:0 0 14px;font-size:15px;color:#3f3f46;">{{.environment}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Alert</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#dc2626;">{{.alert_type}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Message</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.alert_message}}</p>
      </td></tr></table>
      <p style="margin:0 0 24px;font-size:13px;color:#a1a1aa;">{{.timestamp}}</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.dashboard_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View dashboard</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">mark8ly</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"service_name":"","alert_type":"","alert_message":"","timestamp":"","environment":"","dashboard_url":"","platform_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── AUDIT ──────────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'platform',
    'Audit Log Alert',
    'Sent for significant audit events',
    'EMAIL', 'audit',
    'Audit: {{.action}} by {{.actor_name}}',
    'Audit Event

Actor: {{.actor_name}} ({{.actor_email}})
Action: {{.action}}
Resource: {{.resource_type}} {{.resource_id}}
Time: {{.timestamp}}
Details: {{.details}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:#18181b;border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .platform_logo_url}}<img src="{{.platform_logo_url}}" alt="mark8ly" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">mark8ly</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Audit event</h1>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Actor</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.actor_name}} ({{.actor_email}})</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Action</p>
        <p style="margin:0 0 14px;font-size:13px;color:#18181b;font-family:''SF Mono'',SFMono-Regular,Menlo,monospace;">{{.action}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Resource</p>
        <p style="margin:0 0 14px;font-size:15px;color:#3f3f46;">{{.resource_type}} {{.resource_id}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Details</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.details}}</p>
      </td></tr></table>
      <p style="margin:0;font-size:13px;color:#a1a1aa;">{{.timestamp}}</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">mark8ly</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"actor_name":"","actor_email":"","action":"","resource_type":"","resource_id":"","timestamp":"","details":"","platform_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── SECURITY ───────────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'platform',
    'Security Alert',
    'Sent for suspicious login or security events',
    'EMAIL', 'security',
    'Security alert: {{.event_type}}',
    'Security Event Detected

User: {{.user_name}} ({{.user_email}})
Event: {{.event_type}}
IP: {{.ip_address}}
Location: {{.location}}
Time: {{.timestamp}}

Take action: {{.action_url}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:#dc2626;border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .platform_logo_url}}<img src="{{.platform_logo_url}}" alt="mark8ly" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">mark8ly</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">Security alert</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">A security event has been detected on the platform.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fef2f2;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Event</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#dc2626;">{{.event_type}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">User</p>
        <p style="margin:0 0 14px;font-size:15px;color:#18181b;">{{.user_name}} ({{.user_email}})</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">IP / Location</p>
        <p style="margin:0;font-size:15px;color:#3f3f46;">{{.ip_address}} &mdash; {{.location}}</p>
      </td></tr></table>
      <p style="margin:0 0 24px;font-size:13px;color:#a1a1aa;">{{.timestamp}}</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#dc2626;border-radius:6px;">
        <a href="{{.action_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Review event</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">mark8ly</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"user_name":"","user_email":"","event_type":"","ip_address":"","location":"","timestamp":"","action_url":"","platform_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── PLATFORM ADMIN ─────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'platform',
    'New Tenant Signup',
    'Sent to platform admins when a new tenant signs up',
    'EMAIL', 'platform_admin',
    'New tenant: {{.details}}',
    'New tenant signup on mark8ly.

Type: {{.notification_type}}
Details: {{.details}}
Time: {{.timestamp}}

Dashboard: {{.dashboard_url}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:#18181b;border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .platform_logo_url}}<img src="{{.platform_logo_url}}" alt="mark8ly" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">mark8ly</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 24px;font-size:20px;font-weight:600;color:#18181b;">New tenant signup</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">A new tenant has signed up on the platform.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#f0fdf4;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Details</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.details}}</p>
      </td></tr></table>
      <p style="margin:0 0 24px;font-size:13px;color:#a1a1aa;">{{.timestamp}}</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.dashboard_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View dashboard</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">mark8ly</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"admin_name":"","admin_email":"","notification_type":"","details":"","timestamp":"","dashboard_url":"","platform_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

COMMIT;
-- Add slug column, backfill existing templates, insert new templates.

BEGIN;

-- ============================================================================
-- PART 1: Add slug column
-- ============================================================================

ALTER TABLE notification_templates ADD COLUMN IF NOT EXISTS slug VARCHAR(255);

-- ============================================================================
-- PART 2: Backfill slugs for existing 23 templates from migration 004
-- ============================================================================

-- default-tenant templates (19)
UPDATE notification_templates SET slug = 'order-confirmation' WHERE name = 'Order Confirmation' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'order-shipped' WHERE name = 'Order Shipped' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'order-cancelled' WHERE name = 'Order Cancelled' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'payment-confirmation' WHERE name = 'Payment Confirmation' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'payment-failed' WHERE name = 'Payment Failed' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'welcome-email' WHERE name = 'Customer Welcome' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'password-reset' WHERE name = 'Password Reset' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'verification-code' WHERE name = 'Email Verification' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'review-submitted-customer' WHERE name = 'Review Request' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'ticket-created' WHERE name = 'Ticket Created' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'vendor-application' WHERE name = 'Vendor Application Received' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'coupon-created' WHERE name = 'Coupon Created' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'low-stock-alert' WHERE name = 'Low Stock Alert' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'approval-request' WHERE name = 'Approval Required' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'domain-verified' WHERE name = 'Domain Verified' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'campaign-admin' WHERE name = 'Campaign Launched' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'gift-card-recipient' WHERE name = 'Gift Card Received' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'staff-invitation' WHERE name = 'Staff Invitation' AND tenant_id = 'default-tenant';
UPDATE notification_templates SET slug = 'tenant-welcome-pack' WHERE name = 'Tenant Welcome Pack' AND tenant_id = 'default-tenant';

-- platform templates (4)
UPDATE notification_templates SET slug = 'system-health-alert' WHERE name = 'System Health Alert' AND tenant_id = 'platform';
UPDATE notification_templates SET slug = 'audit-log-alert' WHERE name = 'Audit Log Alert' AND tenant_id = 'platform';
UPDATE notification_templates SET slug = 'security-alert' WHERE name = 'Security Alert' AND tenant_id = 'platform';
UPDATE notification_templates SET slug = 'new-tenant-signup' WHERE name = 'New Tenant Signup' AND tenant_id = 'platform';

-- ============================================================================
-- PART 3: Insert new templates
-- ============================================================================

-- ─── 1. order-delivered ────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Order Delivered',
    'order-delivered',
    'Sent when an order has been delivered',
    'EMAIL', 'order',
    'Your order #{{.order_id}} has been delivered',
    'Hi {{.customer_name}}, your order has been delivered. We hope you love it!

Delivered on: {{.delivery_date}}
Location: {{.delivery_location}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Order delivered</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Order #{{.order_id}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your order has been delivered. We hope you love it!</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Delivered on</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.delivery_date}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Location</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.delivery_location}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Leave a review</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"order_id":"","customer_name":"","delivery_date":"","delivery_location":"","store_name":"","store_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 2. payment-refunded ──────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Payment Refunded',
    'payment-refunded',
    'Sent when a payment has been refunded',
    'EMAIL', 'payment',
    'Refund processed — {{.refund_amount}}',
    'Hi {{.customer_name}}, your refund of {{.refund_amount}} has been processed. It may take 5-10 business days to appear.

Amount: {{.refund_amount}}
Transaction: {{.transaction_id}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Refund processed</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.refund_amount}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your refund of {{.refund_amount}} has been processed. It may take 5-10 business days to appear.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Amount</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.refund_amount}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Transaction</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.transaction_id}}</p>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","refund_amount":"","transaction_id":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 3. login-notification ────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Login Notification',
    'login-notification',
    'Sent when a new login is detected',
    'EMAIL', 'auth',
    'New sign-in to your account',
    'Hi {{.customer_name}}, we detected a new sign-in to your account.

Time: {{.login_time}}
Location: {{.login_location}}
IP: {{.ip_address}}
Device: {{.device_info}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">New sign-in detected</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Account security</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, we detected a new sign-in to your account.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Time</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.login_time}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Location</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.login_location}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">IP address</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.ip_address}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Device</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.device_info}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.reset_password_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Secure your account</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","login_time":"","login_location":"","ip_address":"","device_info":"","reset_password_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 4. verification-link ─────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Verification Link',
    'verification-link',
    'Sent during tenant onboarding for email verification',
    'EMAIL', 'tenant_onboarding',
    'Verify your email address',
    'Hi {{.customer_name}}, please verify your email to continue setting up your store.

{{.verification_link}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Verify your email</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Email verification</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, please verify your email to continue setting up your store.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.verification_link}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Verify email</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","verification_link":"","verification_expiry":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 5. review-submitted-admin ────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Review Submitted (Admin)',
    'review-submitted-admin',
    'Sent to admin when a new review is submitted',
    'EMAIL', 'review',
    'New review for {{.product_name}}',
    'A new {{.rating}}-star review has been submitted for {{.product_name}} and requires moderation.

Product: {{.product_name}}
Rating: {{.rating}}/{{.max_rating}}
Customer: {{.customer_name}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">New review submitted</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.product_name}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">A new {{.rating}}-star review has been submitted for {{.product_name}} and requires moderation.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Product</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.product_name}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Rating</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.rating}}/{{.max_rating}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Customer</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.customer_name}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.reviews_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Review now</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"product_name":"","customer_name":"","rating":"","max_rating":"","review_title":"","review_content":"","reviews_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 6. review-approved ───────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Review Approved',
    'review-approved',
    'Sent when a customer review is approved',
    'EMAIL', 'review',
    'Your review has been published',
    'Hi {{.customer_name}}, your review for {{.product_name}} has been approved and is now visible.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Review published</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.product_name}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your review for {{.product_name}} has been approved and is now visible.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.product_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View your review</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","product_name":"","review_title":"","product_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 7. review-rejected ───────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Review Rejected',
    'review-rejected',
    'Sent when a customer review is rejected',
    'EMAIL', 'review',
    'Update on your review',
    'Hi {{.customer_name}}, your review for {{.product_name}} could not be published. Reason: {{.reject_reason}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Review update</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.product_name}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your review for {{.product_name}} could not be published. Reason: {{.reject_reason}}</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.product_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Submit a new review</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","product_name":"","reject_reason":"","product_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 8. ticket-created-admin ──────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Ticket Created (Admin)',
    'ticket-created-admin',
    'Sent to support when a new ticket is created',
    'EMAIL', 'ticket',
    'New support ticket #{{.ticket_number}}',
    'A new support ticket has been created and needs attention.

Ticket: #{{.ticket_number}}
Subject: {{.ticket_subject}}
Priority: {{.ticket_priority}}
Category: {{.ticket_category}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">New support ticket</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">#{{.ticket_number}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">A new support ticket has been created and needs attention.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Ticket</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">#{{.ticket_number}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Subject</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.ticket_subject}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Priority</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.ticket_priority}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Category</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.ticket_category}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.ticket_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View ticket</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"ticket_number":"","ticket_subject":"","ticket_priority":"","ticket_category":"","customer_name":"","customer_email":"","ticket_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 9. ticket-updated ────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Ticket Updated',
    'ticket-updated',
    'Sent when a support ticket is updated',
    'EMAIL', 'ticket',
    'Ticket #{{.ticket_number}} updated',
    'Hi {{.customer_name}}, your support ticket has been updated.

Status: {{.ticket_status}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Ticket updated</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">#{{.ticket_number}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your support ticket has been updated.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Status</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.ticket_status}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.ticket_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View ticket</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","ticket_number":"","ticket_status":"","ticket_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 10. ticket-resolved ──────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Ticket Resolved',
    'ticket-resolved',
    'Sent when a support ticket is resolved',
    'EMAIL', 'ticket',
    'Ticket #{{.ticket_number}} resolved',
    'Hi {{.customer_name}}, your support ticket has been resolved.

Resolution: {{.resolution}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Ticket resolved</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">#{{.ticket_number}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your support ticket has been resolved.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Resolution</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.resolution}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.ticket_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View ticket</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","ticket_number":"","resolution":"","ticket_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 11. ticket-closed ────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Ticket Closed',
    'ticket-closed',
    'Sent when a support ticket is closed',
    'EMAIL', 'ticket',
    'Ticket #{{.ticket_number}} closed',
    'Hi {{.customer_name}}, your support ticket has been closed. If you need further help, feel free to open a new ticket.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Ticket closed</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">#{{.ticket_number}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, your support ticket has been closed. If you need further help, feel free to open a new ticket.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Contact support</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","ticket_number":"","store_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 12. vendor-welcome ───────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Vendor Welcome',
    'vendor-welcome',
    'Welcome email sent to newly registered vendors',
    'EMAIL', 'vendor',
    'Welcome to {{.store_name}}',
    'Hi {{.vendor_name}}, welcome aboard! Your vendor account has been created. You can start setting up your store.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Welcome aboard</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Vendor account</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.vendor_name}}, welcome aboard! Your vendor account has been created. You can start setting up your store.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.vendor_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Get started</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"vendor_name":"","vendor_email":"","vendor_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 13. vendor-approved ──────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Vendor Approved',
    'vendor-approved',
    'Sent when a vendor application is approved',
    'EMAIL', 'vendor',
    'Your vendor application has been approved',
    'Hi {{.vendor_name}}, great news — your application has been approved! You can now start listing products.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Application approved</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Vendor account</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.vendor_name}}, great news — your application has been approved! You can now start listing products.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.vendor_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Go to dashboard</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"vendor_name":"","vendor_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 14. vendor-rejected ──────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Vendor Rejected',
    'vendor-rejected',
    'Sent when a vendor application is rejected',
    'EMAIL', 'vendor',
    'Update on your vendor application',
    'Hi {{.vendor_name}}, unfortunately your application could not be approved at this time. Reason: {{.status_reason}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Application update</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Vendor account</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.vendor_name}}, unfortunately your application could not be approved at this time. Reason: {{.status_reason}}</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"vendor_name":"","status_reason":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 15. vendor-suspended ─────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Vendor Suspended',
    'vendor-suspended',
    'Sent when a vendor account is suspended',
    'EMAIL', 'vendor',
    'Your vendor account has been suspended',
    'Hi {{.vendor_name}}, your vendor account has been suspended. Reason: {{.status_reason}}. Please contact support for more information.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Account suspended</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Vendor account</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.vendor_name}}, your vendor account has been suspended. Reason: {{.status_reason}}. Please contact support for more information.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"vendor_name":"","status_reason":"","support_email":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 16. coupon-applied ───────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Coupon Applied',
    'coupon-applied',
    'Sent when a coupon is applied to an order',
    'EMAIL', 'coupon',
    'Coupon applied — {{.discount_amount}} off',
    'Hi {{.customer_name}}, the coupon {{.coupon_code}} has been applied to your order.

Coupon: {{.coupon_code}}
Discount: {{.discount_amount}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Coupon applied</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.discount_amount}} off</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.customer_name}}, the coupon {{.coupon_code}} has been applied to your order.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Coupon</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.coupon_code}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Discount</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.discount_amount}}</p>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"customer_name":"","coupon_code":"","discount_amount":"","order_value":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 17. coupon-expired ───────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Coupon Expired',
    'coupon-expired',
    'Sent to admin when a coupon expires',
    'EMAIL', 'coupon',
    'Coupon {{.coupon_code}} has expired',
    'The coupon {{.coupon_code}} has expired and is no longer valid.

Code: {{.coupon_code}}
Valid until: {{.valid_until}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Coupon expired</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.coupon_code}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">The coupon {{.coupon_code}} has expired and is no longer valid.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Code</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.coupon_code}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Valid until</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.valid_until}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.coupons_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Manage coupons</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"coupon_code":"","valid_until":"","coupons_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 18. approval-escalated ───────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Approval Escalated',
    'approval-escalated',
    'Sent when an approval request is escalated',
    'EMAIL', 'approval',
    'Approval escalated — {{.action_type_display}}',
    'An approval request has been escalated to you for review.

Action: {{.action_type_display}}
Resource: {{.resource_type}} {{.resource_id}}
Requested by: {{.requester_name}}
Priority: {{.approval_priority}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Approval escalated</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.action_type_display}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">An approval request has been escalated to you for review.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Action</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.action_type_display}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Resource</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.resource_type}} {{.resource_id}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Requested by</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.requester_name}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Priority</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.approval_priority}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.approval_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Review request</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"action_type_display":"","resource_type":"","resource_id":"","requester_name":"","approval_priority":"","approval_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 19. approval-granted ─────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Approval Granted',
    'approval-granted',
    'Sent when an approval request is granted',
    'EMAIL', 'approval',
    'Your request has been approved',
    'Hi {{.requester_name}}, your {{.action_type_display}} request has been approved by {{.approver_name}}.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Request approved</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.action_type_display}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.requester_name}}, your {{.action_type_display}} request has been approved by {{.approver_name}}.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Action</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.action_type_display}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Approved by</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.approver_name}}</p>
        {{if .approval_comment}}<p style="margin:14px 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Comment</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.approval_comment}}</p>{{end}}
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.approval_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View details</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"requester_name":"","action_type_display":"","approver_name":"","approval_comment":"","approval_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 20. approval-rejected ────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Approval Rejected',
    'approval-rejected',
    'Sent when an approval request is rejected',
    'EMAIL', 'approval',
    'Your request was not approved',
    'Hi {{.requester_name}}, your {{.action_type_display}} request was not approved by {{.approver_name}}.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Request not approved</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.action_type_display}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.requester_name}}, your {{.action_type_display}} request was not approved by {{.approver_name}}.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Action</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.action_type_display}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Rejected by</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.approver_name}}</p>
        {{if .approval_comment}}<p style="margin:14px 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Comment</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.approval_comment}}</p>{{end}}
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.approval_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View details</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"requester_name":"","action_type_display":"","approver_name":"","approval_comment":"","approval_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 21. approval-cancelled ───────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Approval Cancelled',
    'approval-cancelled',
    'Sent when an approval request is cancelled',
    'EMAIL', 'approval',
    'Approval request cancelled',
    'Hi {{.requester_name}}, your {{.action_type_display}} approval request has been cancelled.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Request cancelled</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.action_type_display}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.requester_name}}, your {{.action_type_display}} approval request has been cancelled.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"requester_name":"","action_type_display":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 22. approval-expired ─────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Approval Expired',
    'approval-expired',
    'Sent when an approval request expires',
    'EMAIL', 'approval',
    'Approval request expired',
    'Hi {{.requester_name}}, your {{.action_type_display}} approval request has expired. Please submit a new request if still needed.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Request expired</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.action_type_display}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.requester_name}}, your {{.action_type_display}} approval request has expired. Please submit a new request if still needed.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"requester_name":"","action_type_display":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 23. domain-added ─────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain Added',
    'domain-added',
    'Sent when a custom domain is added',
    'EMAIL', 'domain',
    'Domain {{.domain}} added',
    'Hi {{.owner_name}}, the domain {{.domain}} has been added to your store. DNS verification is in progress.

Domain: {{.domain}}
Status: Pending verification

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Domain added</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, the domain {{.domain}} has been added to your store. DNS verification is in progress.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Domain</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.domain}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Status</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">Pending verification</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.domain_settings_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Manage domains</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","domain_settings_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 24. domain-ssl-ready ─────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain SSL Ready',
    'domain-ssl-ready',
    'Sent when SSL is provisioned for a domain',
    'EMAIL', 'domain',
    'SSL certificate ready for {{.domain}}',
    'Hi {{.owner_name}}, an SSL certificate has been issued for {{.domain}}. Your domain is now secure.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">SSL certificate ready</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, an SSL certificate has been issued for {{.domain}}. Your domain is now secure.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.domain_settings_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View domain</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","ssl_provider":"","domain_settings_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 25. domain-activated ─────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain Activated',
    'domain-activated',
    'Sent when a domain is activated and live',
    'EMAIL', 'domain',
    'Domain {{.domain}} is live',
    'Hi {{.owner_name}}, your domain {{.domain}} is now active and serving traffic.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Domain is live</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, your domain {{.domain}} is now active and serving traffic.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="https://{{.domain}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Visit your store</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","domain_settings_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 26. domain-failed ────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain Failed',
    'domain-failed',
    'Sent when domain setup fails',
    'EMAIL', 'domain',
    'Domain setup failed for {{.domain}}',
    'Hi {{.owner_name}}, we were unable to complete the setup for {{.domain}}. Reason: {{.failure_reason}}

Domain: {{.domain}}
Error: {{.failure_reason}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Domain setup failed</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, we were unable to complete the setup for {{.domain}}. Reason: {{.failure_reason}}</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Domain</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.domain}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Error</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.failure_reason}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.domain_settings_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Manage domains</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","failure_reason":"","domain_settings_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 27. domain-removed ───────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain Removed',
    'domain-removed',
    'Sent when a domain is removed',
    'EMAIL', 'domain',
    'Domain {{.domain}} removed',
    'Hi {{.owner_name}}, the domain {{.domain}} has been removed from your store.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Domain removed</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, the domain {{.domain}} has been removed from your store.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 28. domain-migrated ──────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain Migrated',
    'domain-migrated',
    'Sent when a domain is migrated to new infrastructure',
    'EMAIL', 'domain',
    'Domain {{.domain}} migrated',
    'Hi {{.owner_name}}, your domain {{.domain}} has been migrated. Reason: {{.migration_reason}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Domain migrated</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, your domain {{.domain}} has been migrated. Reason: {{.migration_reason}}</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.domain_settings_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">View domain</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","migration_reason":"","migrated_from":"","migrated_to":"","domain_settings_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 29. domain-ssl-expiring ──────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain SSL Expiring',
    'domain-ssl-expiring',
    'Sent when an SSL certificate is about to expire',
    'EMAIL', 'domain',
    'SSL certificate expiring for {{.domain}}',
    'Hi {{.owner_name}}, the SSL certificate for {{.domain}} will expire on {{.ssl_expires_at}}. Renewal is in progress.

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">SSL certificate expiring</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, the SSL certificate for {{.domain}} will expire on {{.ssl_expires_at}}. Renewal is in progress.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.domain_settings_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Manage domains</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","ssl_expires_at":"","domain_settings_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 30. domain-health-failed ─────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Domain Health Failed',
    'domain-health-failed',
    'Sent when domain health check fails',
    'EMAIL', 'domain',
    'Health check failed for {{.domain}}',
    'Hi {{.owner_name}}, the health check for {{.domain}} has failed. Our team is investigating.

Domain: {{.domain}}
Error: {{.failure_reason}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Health check failed</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">{{.domain}}</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.owner_name}}, the health check for {{.domain}} has failed. Our team is investigating.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Domain</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.domain}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Error</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.failure_reason}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.domain_settings_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Manage domains</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"owner_name":"","domain":"","failure_reason":"","domain_settings_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 31. gift-card-purchaser ──────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Gift Card Purchase Confirmation',
    'gift-card-purchaser',
    'Sent to the purchaser after buying a gift card',
    'EMAIL', 'gift_card',
    'Your gift card purchase is confirmed',
    'Hi {{.purchaser_name}}, your gift card has been purchased and delivered to {{.recipient_name}}.

Code: {{.gift_card_code}}
Amount: {{.gift_card_balance}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Gift card purchased</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Purchase confirmation</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.purchaser_name}}, your gift card has been purchased and delivered to {{.recipient_name}}.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Code</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.gift_card_code}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Amount</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.gift_card_balance}}</p>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"purchaser_name":"","recipient_name":"","gift_card_code":"","gift_card_balance":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 32. gift-card-activated ──────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Gift Card Activated',
    'gift-card-activated',
    'Sent when a gift card is activated',
    'EMAIL', 'gift_card',
    'Your gift card is ready to use',
    'Hi {{.recipient_name}}, your gift card has been activated and is ready to use.

Code: {{.gift_card_code}}
Balance: {{.gift_card_balance}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 4px;font-size:20px;font-weight:600;color:#18181b;">Gift card activated</h1>
      <p style="margin:0 0 24px;font-size:14px;color:#71717a;">Ready to use</p>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.recipient_name}}, your gift card has been activated and is ready to use.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#fafafa;border-radius:8px;">
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Code</p>
        <p style="margin:0 0 14px;font-size:15px;font-weight:600;color:#18181b;">{{.gift_card_code}}</p>
        <p style="margin:0 0 2px;font-size:12px;color:#a1a1aa;text-transform:uppercase;letter-spacing:.5px;">Balance</p>
        <p style="margin:0;font-size:15px;font-weight:600;color:#18181b;">{{.gift_card_balance}}</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.store_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Start shopping</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"recipient_name":"","gift_card_code":"","gift_card_balance":"","store_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 33. campaign-broadcast ───────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Campaign Broadcast',
    'campaign-broadcast',
    'Used for broadcast campaign emails',
    'EMAIL', 'campaign',
    '{{.campaign_name}}',
    '{{.campaign_name}} - {{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      {{.campaign_body}}
      {{if .campaign_cta_url}}<table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0 0;"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.campaign_cta_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">{{.campaign_cta_text}}</a>
      </td></tr></table>{{end}}
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
  <p style="margin:8px 0 0;font-size:11px;color:#d4d4d8;"><a href="{{.unsubscribe_url}}" style="color:#a1a1aa;text-decoration:none;">Unsubscribe</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"campaign_name":"","campaign_body":"","campaign_cta_text":"","campaign_cta_url":"","unsubscribe_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 34. campaign-newsletter ──────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Campaign Newsletter',
    'campaign-newsletter',
    'Used for newsletter campaign emails',
    'EMAIL', 'campaign',
    '{{.campaign_name}}',
    '{{.campaign_name}} - {{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      {{.campaign_body}}
      {{if .campaign_cta_url}}<table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0 0;"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.campaign_cta_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">{{.campaign_cta_text}}</a>
      </td></tr></table>{{end}}
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
  <p style="margin:8px 0 0;font-size:11px;color:#d4d4d8;"><a href="{{.unsubscribe_url}}" style="color:#a1a1aa;text-decoration:none;">Unsubscribe</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"campaign_name":"","campaign_body":"","campaign_cta_text":"","campaign_cta_url":"","unsubscribe_url":"","store_name":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ============================================================================
-- PART 4: Constraints
-- ============================================================================

-- Backfill any remaining NULL slugs as fallback
UPDATE notification_templates SET slug = LOWER(REPLACE(REPLACE(REPLACE(name, ' ', '-'), '(', ''), ')', '')) WHERE slug IS NULL;

ALTER TABLE notification_templates ALTER COLUMN slug SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_template_slug_tenant ON notification_templates(slug, tenant_id) WHERE deleted_at IS NULL;

COMMIT;
-- Add missing templates: customer-goodbye, customer-otp, draft-reminder
-- These were previously rendered as hardcoded HTML in tenant-service and verification-service.

BEGIN;

-- ─── 1. customer-goodbye ────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Customer Goodbye',
    'customer-goodbye',
    'Sent when a customer deactivates their account',
    'EMAIL', 'customer',
    'We''re sorry to see you go from {{.store_name}}',
    'Hi {{.first_name}},

Your account at {{.store_name}} has been deactivated as requested.

Your data will be safely retained for 90 days. You can reactivate your account anytime before {{.purge_date}}.

After 90 days, your data will be permanently deleted.

Changed your mind? Simply log back in to reactivate: {{.reactivation_url}}

{{.store_name}}',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#64748b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 20px;font-size:20px;font-weight:600;color:#18181b;">We''re sorry to see you go</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.first_name}}, your account at <strong>{{.store_name}}</strong> has been deactivated as requested.</p>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;"><tr><td style="padding:16px 20px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:0 8px 8px 0;">
        <p style="margin:0 0 8px;font-size:14px;font-weight:600;color:#92400e;">What happens next?</p>
        <p style="margin:0;font-size:14px;line-height:1.7;color:#92400e;">Your data will be safely retained for <strong>90 days</strong>. You can reactivate anytime before <strong>{{.purge_date}}</strong>. After that, your data will be permanently deleted.</p>
      </td></tr></table>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;"><tr><td style="padding:16px 20px;background:#ecfdf5;border-left:3px solid #10b981;border-radius:0 8px 8px 0;">
        <p style="margin:0 0 4px;font-size:14px;font-weight:600;color:#166534;">Changed your mind?</p>
        <p style="margin:0;font-size:14px;color:#166534;">Simply log back in to reactivate your account. All your data will be restored instantly.</p>
      </td></tr></table>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto;"><tr><td style="background:#10b981;border-radius:6px;">
        <a href="{{.reactivation_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Reactivate My Account</a>
      </td></tr></table>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"first_name":"","store_name":"","purge_date":"","reactivation_url":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 2. customer-otp ────────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Customer OTP',
    'customer-otp',
    'OTP code sent to storefront customers for email verification',
    'EMAIL', 'customer',
    'Your verification code for {{.store_name}}',
    'Hi,

Your verification code for {{.store_name}} is: {{.verification_code}}

This code will expire in {{.expiry_minutes}} minutes.

If you did not request this code, please ignore this email.',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:{{if .brand_primary_color}}{{.brand_primary_color}}{{else}}#18181b{{end}};border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      {{if .brand_logo_url}}<img src="{{.brand_logo_url}}" alt="{{.store_name}}" height="28" style="height:28px;max-width:140px;">{{else}}<span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">{{.store_name}}</span>{{end}}
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 20px;font-size:20px;font-weight:600;color:#18181b;">Verify your email address</h1>
      <p style="margin:0 0 24px;font-size:15px;line-height:1.65;color:#3f3f46;">Enter the code below to verify your email for <strong>{{.store_name}}</strong>.</p>
      <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 24px;"><tr><td style="padding:16px 32px;background:#fafafa;border-radius:8px;border:1px solid #e4e4e7;">
        <span style="font-size:32px;font-weight:700;letter-spacing:8px;color:#18181b;font-family:''SF Mono'',''Fira Code'',''Fira Mono'',''Roboto Mono'',monospace;">{{.verification_code}}</span>
      </td></tr></table>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;"><tr><td style="padding:12px 16px;background:#fffbeb;border-left:3px solid #f59e0b;border-radius:0 8px 8px 0;">
        <p style="margin:0;font-size:13px;color:#92400e;">This code expires in <strong>{{.expiry_minutes}} minutes</strong>.</p>
      </td></tr></table>
      <p style="margin:0;font-size:13px;color:#a1a1aa;">If you did not request this code, please ignore this email.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">{{.store_name}}</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"verification_code":"","store_name":"","expiry_minutes":"10","email":"","brand_primary_color":"","brand_logo_url":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 3. draft-reminder ──────────────────────────────────────────────────────

INSERT INTO notification_templates (
    id, tenant_id, name, slug, description, channel, category,
    subject, body_template, html_template,
    variables, is_active, is_system, version
) VALUES (
    gen_random_uuid(), 'default-tenant',
    'Draft Reminder',
    'draft-reminder',
    'Reminder email for incomplete onboarding sessions',
    'EMAIL', 'tenant_onboarding',
    'Continue setting up your store',
    'Hi {{.first_name}},

It looks like you started setting up your store but haven''t finished yet.

Pick up right where you left off: {{.continue_url}}

If you need help, reply to this email and we''ll be happy to assist.',
    '<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,''Segoe UI'',Roboto,''Helvetica Neue'',Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;"><tr><td style="padding:48px 24px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:512px;margin:0 auto;">
<tr><td>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#fff;border-radius:12px;border:1px solid #e4e4e7;">
    <tr><td style="height:3px;background:#18181b;border-radius:12px 12px 0 0;font-size:0;line-height:0;">&nbsp;</td></tr>
    <tr><td style="padding:32px 32px 0;text-align:center;">
      <span style="font-size:15px;font-weight:600;color:#18181b;letter-spacing:-.2px;">mark8ly</span>
    </td></tr>
    <tr><td style="padding:28px 32px 36px;">
      <h1 style="margin:0 0 20px;font-size:20px;font-weight:600;color:#18181b;">Continue setting up your store</h1>
      <p style="margin:0 0 20px;font-size:15px;line-height:1.65;color:#3f3f46;">Hi {{.first_name}}, it looks like you started setting up your store but haven''t finished yet. Your progress has been saved — pick up right where you left off.</p>
      <table role="presentation" cellpadding="0" cellspacing="0"><tr><td style="background:#18181b;border-radius:6px;">
        <a href="{{.continue_url}}" style="display:inline-block;padding:11px 24px;font-size:14px;font-weight:500;color:#fff;text-decoration:none;">Continue Setup &rarr;</a>
      </td></tr></table>
      <p style="margin:20px 0 0;font-size:13px;color:#a1a1aa;">Need help? Reply to this email and we''ll be happy to assist.</p>
    </td></tr>
  </table>
</td></tr>
<tr><td style="padding:20px 0 0;text-align:center;">
  <p style="margin:0;font-size:12px;color:#a1a1aa;">mark8ly</p>
  <p style="margin:6px 0 0;font-size:11px;color:#d4d4d8;">Powered by <a href="https://mark8ly.com" style="color:#a1a1aa;text-decoration:none;">mark8ly</a></p>
</td></tr>
</table>
</td></tr></table>
</body></html>',
    '{"first_name":"","continue_url":"","session_id":""}',
    true, true, 1
) ON CONFLICT DO NOTHING;

-- ─── 4. verification-link (add slug to existing template) ───────────────────
-- The verification-link template was added in 005 but may not have a slug in
-- older environments. Ensure it exists by upserting.

UPDATE notification_templates
SET slug = 'verification-link'
WHERE name = 'Verification Link' AND slug IS NULL;

COMMIT;
-- Migration 007: Rebrand email templates from Tesserix to mark8ly
-- Updates all existing notification_templates in the DB

-- Update HTML templates: replace branding text and links
UPDATE notification_templates
SET html_template = REPLACE(
      REPLACE(
        REPLACE(html_template, 'Tesserix', 'mark8ly'),
        'tesserix.app', 'mark8ly.com'
      ),
      'Tesseract Hub', 'mark8ly'
    ),
    body_template = REPLACE(
      REPLACE(
        REPLACE(body_template, 'Tesserix', 'mark8ly'),
        'tesserix.app', 'mark8ly.com'
      ),
      'Tesseract Hub', 'mark8ly'
    ),
    updated_at = NOW()
WHERE html_template LIKE '%Tesserix%'
   OR html_template LIKE '%tesserix.app%'
   OR html_template LIKE '%Tesseract Hub%'
   OR body_template LIKE '%Tesserix%'
   OR body_template LIKE '%tesserix.app%'
   OR body_template LIKE '%Tesseract Hub%';

-- Update subject lines too
UPDATE notification_templates
SET subject = REPLACE(
      REPLACE(
        REPLACE(subject, 'Tesserix', 'mark8ly'),
        'tesserix.app', 'mark8ly.com'
      ),
      'Tesseract Hub', 'mark8ly'
    ),
    updated_at = NOW()
WHERE subject LIKE '%Tesserix%'
   OR subject LIKE '%tesserix.app%'
   OR subject LIKE '%Tesseract Hub%';
